// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {IAndxEscrow} from "./interfaces/IAndxEscrow.sol";

/// @title AndxEscrow
/// @notice Campaign escrow with Merkle cumulative payouts and gasless claimWithSig.
/// @dev Decision (4.5): pending roots survive operator rotate/revoke. Only `operator`
///      changes. After revoke, operator is address(0) so no new proposals; anyone may
///      still activateRoot after delay, and guardian may still vetoRoot.
contract AndxEscrow is IAndxEscrow, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------
    error Unauthorized();
    error PausedError();
    error ZeroAddress();
    error ZeroAmount();
    error TokenNotAllowed();
    error CampaignExists();
    error CampaignMissing();
    error BadEndTime();
    error NothingReceived();
    error EpochInvalid();
    error PendingExists();
    error NothingPending();
    error RootZero();
    error BadCampaignOrder();
    error LengthMismatch();
    error CommitmentDecreased();
    error ExceedsEpochCap();
    error ExceedsBudget();
    error CampaignEnded();
    error TooEarly();
    error BadProof();
    error NothingToClaim();
    error RecipientZero();
    error FeeTooHigh();
    error ClaimedExceedsCommitted();
    error BadSignature();
    error NonceUsed();
    error DeadlineExpired();
    error NotCreator();
    error OperatorNotQueued();
    error OperatorDelayPending();

    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------
    struct Campaign {
        address brand;
        address token;
        uint64 endTime;
        uint256 maxCommitPerEpoch;
        uint256 netDeposited;
        uint256 activeCommitted;
        uint256 claimedTotal;
        uint256 refunded;
    }

    struct PendingRootData {
        uint64 epoch;
        bytes32 root;
        uint64 activatesAt;
        // campaignId => newCommitted for campaigns listed in the pending proposal
        mapping(bytes32 => uint256) committed;
        // campaignId => whether listed in pending proposal
        mapping(bytes32 => bool) listed;
        bytes32[] campaignIds;
    }

    // ---------------------------------------------------------------------
    // EIP-712
    // ---------------------------------------------------------------------
    bytes32 private constant CLAIM_AUTH_TYPEHASH = keccak256(
        "ClaimAuth(bytes32 campaignId,address creator,uint256 cumulativeAmount,address recipient,uint256 relayerFee,uint256 nonce,uint256 deadline)"
    );
    bytes32 private constant TYPE_HASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant NAME_HASH = keccak256(bytes("ANDX Escrow"));
    bytes32 private constant VERSION_HASH = keccak256(bytes("1"));

    // ---------------------------------------------------------------------
    // Immutable / storage
    // ---------------------------------------------------------------------
    address public override owner;
    address public override operator;
    address public override guardian;
    uint64 public immutable override ROOT_DELAY;
    uint64 public immutable override OPERATOR_DELAY;

    bool public override paused;

    address private _queuedOperator;
    uint64 private _queuedOperatorEffectiveAt;

    uint64 private _lastEpoch;
    uint64 private _activeEpoch;
    bytes32 private _activeRoot;

    PendingRootData private _pending;

    mapping(address => bool) public override tokenAllowed;
    mapping(bytes32 => Campaign) private _campaigns;
    mapping(bytes32 => mapping(address => uint256)) private _claimedBy;
    mapping(address => mapping(uint256 => bool)) private _nonceUsed;

    // ---------------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------------
    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert PausedError();
        _;
    }

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------
    constructor(address owner_, address operator_, address guardian_, uint64 rootDelay_, uint64 operatorDelay_) {
        if (owner_ == address(0) || operator_ == address(0) || guardian_ == address(0)) revert ZeroAddress();
        owner = owner_;
        operator = operator_;
        guardian = guardian_;
        ROOT_DELAY = rootDelay_;
        OPERATOR_DELAY = operatorDelay_;
    }

    // ---------------------------------------------------------------------
    // Brands
    // ---------------------------------------------------------------------
    function createCampaign(address token, uint256 amount, uint64 endTime, uint256 maxCommitPerEpoch, bytes32 salt)
        external
        override
        nonReentrant
        whenNotPaused
        returns (bytes32 campaignId)
    {
        if (!tokenAllowed[token]) revert TokenNotAllowed();
        if (amount == 0) revert ZeroAmount();
        if (endTime <= block.timestamp) revert BadEndTime();

        campaignId = keccak256(abi.encode(msg.sender, salt));
        if (_campaigns[campaignId].brand != address(0)) revert CampaignExists();

        IERC20 erc20 = IERC20(token);
        uint256 beforeBal = erc20.balanceOf(address(this));
        erc20.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = erc20.balanceOf(address(this)) - beforeBal;
        if (received == 0) revert NothingReceived();

        Campaign storage c = _campaigns[campaignId];
        c.brand = msg.sender;
        c.token = token;
        c.endTime = endTime;
        c.maxCommitPerEpoch = maxCommitPerEpoch;
        c.netDeposited = received;

        emit CampaignCreated(campaignId, msg.sender, token, endTime, maxCommitPerEpoch, received);
    }

    function refundUnallocated(bytes32 campaignId)
        external
        override
        nonReentrant
        whenNotPaused
        returns (uint256 amount)
    {
        Campaign storage c = _campaigns[campaignId];
        if (c.brand == address(0)) revert CampaignMissing();
        if (msg.sender != c.brand) revert Unauthorized();
        if (block.timestamp < uint256(c.endTime) + uint256(ROOT_DELAY)) revert TooEarly();

        uint256 reserved = c.activeCommitted;
        uint256 pend = pendingCommitted(campaignId);
        if (pend > reserved) reserved = pend;

        uint256 available = c.netDeposited - c.refunded;
        if (available <= reserved) {
            return 0;
        }
        amount = available - reserved;
        c.refunded += amount;
        emit Refunded(campaignId, c.brand, amount);

        IERC20(c.token).safeTransfer(c.brand, amount);
    }

    // ---------------------------------------------------------------------
    // Roots
    // ---------------------------------------------------------------------
    function proposeRoot(uint64 epoch, bytes32 root, bytes32[] calldata campaignIds, uint256[] calldata newCommitted)
        external
        override
        whenNotPaused
    {
        if (msg.sender != operator) revert Unauthorized();
        if (root == bytes32(0)) revert RootZero();
        if (epoch != _lastEpoch + 1) revert EpochInvalid();
        if (_pending.epoch != 0) revert PendingExists();
        if (campaignIds.length != newCommitted.length) revert LengthMismatch();

        // Validate strictly increasing campaignIds and commitment rules
        bytes32 prev;
        for (uint256 i = 0; i < campaignIds.length; ++i) {
            bytes32 id = campaignIds[i];
            if (i > 0 && !(uint256(id) > uint256(prev))) revert BadCampaignOrder();
            prev = id;

            Campaign storage c = _campaigns[id];
            if (c.brand == address(0)) revert CampaignMissing();

            uint256 nc = newCommitted[i];
            if (nc < c.activeCommitted) revert CommitmentDecreased();
            if (nc - c.activeCommitted > c.maxCommitPerEpoch) revert ExceedsEpochCap();
            if (nc > c.netDeposited - c.refunded) revert ExceedsBudget();
            if (block.timestamp >= c.endTime && nc > c.activeCommitted) revert CampaignEnded();
        }

        // Advance epoch counter even for proposals that may later be vetoed
        _lastEpoch = epoch;

        _pending.epoch = epoch;
        _pending.root = root;
        _pending.activatesAt = uint64(block.timestamp) + ROOT_DELAY;

        // Clear previous listing maps by overwriting listed set
        // (pending was empty; first write)
        delete _pending.campaignIds;
        for (uint256 i = 0; i < campaignIds.length; ++i) {
            bytes32 id = campaignIds[i];
            _pending.campaignIds.push(id);
            _pending.listed[id] = true;
            _pending.committed[id] = newCommitted[i];
        }

        emit RootProposed(epoch, root, _pending.activatesAt, campaignIds, newCommitted);
    }

    function activateRoot(uint64 epoch) external override whenNotPaused {
        if (_pending.epoch == 0 || _pending.epoch != epoch) revert NothingPending();
        if (block.timestamp < _pending.activatesAt) revert TooEarly();

        _activeEpoch = epoch;
        _activeRoot = _pending.root;

        uint256 len = _pending.campaignIds.length;
        for (uint256 i = 0; i < len; ++i) {
            bytes32 id = _pending.campaignIds[i];
            _campaigns[id].activeCommitted = _pending.committed[id];
            _pending.listed[id] = false;
            _pending.committed[id] = 0;
        }
        delete _pending.campaignIds;
        _pending.epoch = 0;
        _pending.root = bytes32(0);
        _pending.activatesAt = 0;

        emit RootActivated(epoch, _activeRoot);
    }

    function vetoRoot(uint64 epoch) external override {
        // Allowed while paused
        if (msg.sender != guardian) revert Unauthorized();
        if (_pending.epoch == 0 || _pending.epoch != epoch) revert NothingPending();

        uint256 len = _pending.campaignIds.length;
        for (uint256 i = 0; i < len; ++i) {
            bytes32 id = _pending.campaignIds[i];
            _pending.listed[id] = false;
            _pending.committed[id] = 0;
        }
        delete _pending.campaignIds;
        _pending.epoch = 0;
        _pending.root = bytes32(0);
        _pending.activatesAt = 0;

        emit RootVetoed(epoch);
    }

    // ---------------------------------------------------------------------
    // Operator / pause / tokens
    // ---------------------------------------------------------------------
    function queueOperator(address newOperator) external override onlyOwner whenNotPaused {
        if (newOperator == address(0)) revert ZeroAddress();
        _queuedOperator = newOperator;
        _queuedOperatorEffectiveAt = uint64(block.timestamp) + OPERATOR_DELAY;
        emit OperatorQueued(newOperator, _queuedOperatorEffectiveAt);
    }

    function applyOperator() external override whenNotPaused {
        if (_queuedOperator == address(0)) revert OperatorNotQueued();
        if (block.timestamp < _queuedOperatorEffectiveAt) revert OperatorDelayPending();
        address old = operator;
        address neu = _queuedOperator;
        operator = neu;
        _queuedOperator = address(0);
        _queuedOperatorEffectiveAt = 0;
        // Pending root intentionally preserved (ADR-0001)
        emit OperatorChanged(old, neu);
    }

    function revokeOperator() external override {
        if (msg.sender != owner && msg.sender != guardian) revert Unauthorized();
        address old = operator;
        operator = address(0);
        _queuedOperator = address(0);
        _queuedOperatorEffectiveAt = 0;
        // Pending root intentionally preserved (ADR-0001)
        emit OperatorRevoked(old);
    }

    function pause() external override {
        if (msg.sender != owner && msg.sender != guardian) revert Unauthorized();
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external override onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    function setTokenAllowed(address token, bool allowed) external override onlyOwner whenNotPaused {
        if (token == address(0)) revert ZeroAddress();
        tokenAllowed[token] = allowed;
        emit TokenAllowed(token, allowed);
    }

    // ---------------------------------------------------------------------
    // Claims
    // ---------------------------------------------------------------------
    function claim(Claim calldata c, address recipient, bytes32[] calldata proof)
        external
        override
        nonReentrant
        whenNotPaused
    {
        if (msg.sender != c.creator) revert NotCreator();
        _payClaim(c.campaignId, c.creator, c.cumulativeAmount, recipient, 0, proof);
    }

    function claimWithSig(ClaimAuth calldata auth, bytes calldata signature, bytes32[] calldata proof)
        external
        override
        nonReentrant
        whenNotPaused
    {
        if (block.timestamp > auth.deadline) revert DeadlineExpired();
        if (_nonceUsed[auth.creator][auth.nonce]) revert NonceUsed();

        bytes32 digest = hashClaimAuth(auth);
        address recovered = _recover(digest, signature);
        if (recovered == address(0) || recovered != auth.creator) revert BadSignature();

        // Consume nonce only on successful claim — mark before external calls after checks
        // We set after payout amount validated inside _payClaim path; use internal that marks.
        _payClaimWithNonce(auth, proof);
    }

    function _payClaimWithNonce(ClaimAuth calldata auth, bytes32[] calldata proof) internal {
        Campaign storage camp = _campaigns[auth.campaignId];
        if (camp.brand == address(0)) revert CampaignMissing();
        if (auth.recipient == address(0)) revert RecipientZero();

        bytes32 leafHash = leaf(auth.campaignId, auth.creator, auth.cumulativeAmount);
        if (!MerkleProof.verify(proof, _activeRoot, leafHash)) revert BadProof();

        uint256 already = _claimedBy[auth.campaignId][auth.creator];
        if (auth.cumulativeAmount <= already) revert NothingToClaim();
        uint256 payout = auth.cumulativeAmount - already;
        if (auth.relayerFee > payout) revert FeeTooHigh();

        uint256 newClaimedTotal = camp.claimedTotal + payout;
        if (newClaimedTotal > camp.activeCommitted) revert ClaimedExceedsCommitted();

        // Effects
        _nonceUsed[auth.creator][auth.nonce] = true;
        _claimedBy[auth.campaignId][auth.creator] = auth.cumulativeAmount;
        camp.claimedTotal = newClaimedTotal;
        emit Claimed(auth.campaignId, auth.creator, auth.recipient, auth.cumulativeAmount, payout, auth.relayerFee);

        uint256 toRecipient = payout - auth.relayerFee;
        IERC20 token = IERC20(camp.token);
        if (auth.relayerFee > 0) {
            token.safeTransfer(msg.sender, auth.relayerFee);
        }
        if (toRecipient > 0) {
            token.safeTransfer(auth.recipient, toRecipient);
        }
    }

    function _payClaim(
        bytes32 campaignId,
        address creator,
        uint256 cumulativeAmount,
        address recipient,
        uint256 relayerFee,
        bytes32[] calldata proof
    ) internal {
        Campaign storage camp = _campaigns[campaignId];
        if (camp.brand == address(0)) revert CampaignMissing();
        if (recipient == address(0)) revert RecipientZero();

        bytes32 leafHash = leaf(campaignId, creator, cumulativeAmount);
        if (!MerkleProof.verify(proof, _activeRoot, leafHash)) revert BadProof();

        uint256 already = _claimedBy[campaignId][creator];
        if (cumulativeAmount <= already) revert NothingToClaim();
        uint256 payout = cumulativeAmount - already;
        if (relayerFee > payout) revert FeeTooHigh();

        uint256 newClaimedTotal = camp.claimedTotal + payout;
        if (newClaimedTotal > camp.activeCommitted) revert ClaimedExceedsCommitted();

        _claimedBy[campaignId][creator] = cumulativeAmount;
        camp.claimedTotal = newClaimedTotal;
        emit Claimed(campaignId, creator, recipient, cumulativeAmount, payout, relayerFee);

        uint256 toRecipient = payout - relayerFee;
        IERC20 token = IERC20(camp.token);
        if (relayerFee > 0) {
            token.safeTransfer(msg.sender, relayerFee);
        }
        if (toRecipient > 0) {
            token.safeTransfer(recipient, toRecipient);
        }
    }

    /// @dev ECDSA recover with low-s enforcement; returns address(0) on failure.
    function _recover(bytes32 digest, bytes calldata signature) internal pure returns (address) {
        if (signature.length != 65) return address(0);
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }
        // EIP-2: reject high-s
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) {
            return address(0);
        }
        if (v != 27 && v != 28) return address(0);
        return ecrecover(digest, v, r, s);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------
    function campaignState(bytes32 campaignId)
        external
        view
        override
        returns (
            address brand,
            address token,
            uint64 endTime,
            uint256 maxCommitPerEpoch,
            uint256 netDeposited,
            uint256 activeCommitted,
            uint256 pendingCommitted_,
            uint256 claimedTotal,
            uint256 refunded
        )
    {
        Campaign storage c = _campaigns[campaignId];
        brand = c.brand;
        token = c.token;
        endTime = c.endTime;
        maxCommitPerEpoch = c.maxCommitPerEpoch;
        netDeposited = c.netDeposited;
        activeCommitted = c.activeCommitted;
        pendingCommitted_ = pendingCommitted(campaignId);
        claimedTotal = c.claimedTotal;
        refunded = c.refunded;
    }

    function pendingCommitted(bytes32 campaignId) public view returns (uint256) {
        if (_pending.epoch != 0 && _pending.listed[campaignId]) {
            return _pending.committed[campaignId];
        }
        return _campaigns[campaignId].activeCommitted;
    }

    function claimedBy(bytes32 campaignId, address creator) external view override returns (uint256) {
        return _claimedBy[campaignId][creator];
    }

    function activeRoot() external view override returns (uint64 epoch, bytes32 root) {
        return (_activeEpoch, _activeRoot);
    }

    function pendingRoot() external view override returns (uint64 epoch, bytes32 root, uint64 activatesAt) {
        if (_pending.epoch == 0) return (0, bytes32(0), 0);
        return (_pending.epoch, _pending.root, _pending.activatesAt);
    }

    function lastEpoch() external view override returns (uint64) {
        return _lastEpoch;
    }

    function queuedOperator() external view override returns (address newOperator, uint64 effectiveAt) {
        return (_queuedOperator, _queuedOperatorEffectiveAt);
    }

    function nonceUsed(address creator, uint256 nonce) external view override returns (bool) {
        return _nonceUsed[creator][nonce];
    }

    function hashClaimAuth(ClaimAuth calldata auth) public view override returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                CLAIM_AUTH_TYPEHASH,
                auth.campaignId,
                auth.creator,
                auth.cumulativeAmount,
                auth.recipient,
                auth.relayerFee,
                auth.nonce,
                auth.deadline
            )
        );
        bytes32 domainSeparator = keccak256(abi.encode(TYPE_HASH, NAME_HASH, VERSION_HASH, block.chainid, address(this)));
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function leaf(bytes32 campaignId, address creator, uint256 cumulativeAmount)
        public
        view
        override
        returns (bytes32)
    {
        // OpenZeppelin StandardMerkleTree double-hash for value types
        // ["uint256","address","bytes32","address","uint256"]
        return keccak256(
            bytes.concat(
                keccak256(abi.encode(block.chainid, address(this), campaignId, creator, cumulativeAmount))
            )
        );
    }
}
