// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

/// @title LegacyPayouts
/// @notice Escrow for clip campaigns, deployed behind an ERC1967 proxy and shared by all brands.
///         Brands fund campaigns. The operator proposes a per-campaign Merkle root of cumulative
///         creator earnings; after ROOT_DELAY anyone activates it and creators claim. A guardian
///         can veto a pending root. The operator can also sign one-off bonus vouchers.
///         A platform fee is taken on every payout.
contract LegacyPayouts is UUPSUpgradeable {
    struct Campaign {
        address brand;
        IERC20 token;
        uint64 endTime;
        uint256 budget;
        uint256 committed;
        uint256 claimedTotal;
        bytes32 root;
        bytes32 pendingRoot;
        uint64 pendingAt;
    }

    uint64 public constant ROOT_DELAY = 1 hours;

    address public owner;
    address public operator;
    address public guardian;
    address public treasury;
    uint16 public feeBps;

    uint256 public nextCampaignId;
    mapping(uint256 => Campaign) public campaigns;
    mapping(uint256 => mapping(address => uint256)) public claimed;
    mapping(bytes32 => bool) public usedVouchers;
    mapping(address => uint256) public feesOwed;

    event CampaignFunded(uint256 indexed id, address indexed brand, address token, uint256 received, uint64 endTime);
    event RootProposed(uint256 indexed id, bytes32 root, uint256 committed, uint64 activatesAt);
    event RootActivated(uint256 indexed id, bytes32 root);
    event RootVetoed(uint256 indexed id, bytes32 root);
    event Paid(uint256 indexed id, address indexed creator, uint256 net, uint256 fee);
    event CreatorMigrated(uint256 indexed id, address indexed from, address indexed to);
    event Refunded(uint256 indexed id, uint256 amount);

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    function initialize(address _owner, address _operator, address _guardian, address _treasury, uint16 _feeBps)
        external
    {
        require(_feeBps <= 2000, "fee too high");
        owner = _owner;
        operator = _operator;
        guardian = _guardian;
        treasury = _treasury;
        feeBps = _feeBps;
    }

    // ------------------------------------------------------------------ admin
    function setOperator(address newOperator) external onlyOwner {
        require(newOperator != address(0), "zero operator");
        operator = newOperator;
    }

    /// @notice Emergency switch if the operator key is compromised.
    function revokeOperator() external {
        require(msg.sender == owner || msg.sender == guardian, "not allowed");
        operator = address(0);
    }

    function withdrawFees(IERC20 token) external {
        uint256 amount = feesOwed[address(token)];
        feesOwed[address(token)] = 0;
        require(token.transfer(treasury, amount), "fee transfer failed");
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    // ------------------------------------------------------------------ brands
    function fund(IERC20 token, uint256 amount, uint64 endTime) external returns (uint256 id) {
        require(amount > 0, "zero amount");
        require(endTime > block.timestamp, "bad end time");
        uint256 before = token.balanceOf(address(this));
        require(token.transferFrom(msg.sender, address(this), amount), "transferFrom failed");
        uint256 received = token.balanceOf(address(this)) - before;

        id = nextCampaignId++;
        Campaign storage c = campaigns[id];
        c.brand = msg.sender;
        c.token = token;
        c.endTime = endTime;
        c.budget = received;
        emit CampaignFunded(id, msg.sender, address(token), received, endTime);
    }

    function topUp(uint256 id, uint256 amount) external {
        Campaign storage c = campaigns[id];
        require(msg.sender == c.brand, "not brand");
        require(block.timestamp < c.endTime, "ended");
        c.token.transferFrom(msg.sender, address(this), amount);
        c.budget += amount;
    }

    function refund(uint256 id) external {
        Campaign storage c = campaigns[id];
        require(msg.sender == c.brand, "not brand");
        require(block.timestamp >= c.endTime + ROOT_DELAY, "too early");

        uint256 amount = c.budget - (c.committed - c.claimedTotal);
        require(amount > 0, "nothing to refund");
        c.budget -= amount;
        require(c.token.transfer(c.brand, amount), "refund failed");
        emit Refunded(id, amount);
    }

    // ------------------------------------------------------------------ roots
    function proposeRoot(uint256 id, bytes32 root, uint256 newCommitted) external {
        require(msg.sender == operator, "not operator");
        Campaign storage c = campaigns[id];
        require(c.brand != address(0), "no campaign");
        require(newCommitted >= c.committed, "commitment decreased");
        require(newCommitted - c.claimedTotal <= c.budget, "underfunded");
        c.committed = newCommitted;
        c.pendingRoot = root;
        c.pendingAt = uint64(block.timestamp) + ROOT_DELAY;
        emit RootProposed(id, root, newCommitted, c.pendingAt);
    }

    function activateRoot(uint256 id) external {
        Campaign storage c = campaigns[id];
        require(c.pendingRoot != bytes32(0), "nothing pending");
        require(block.timestamp >= c.pendingAt, "too early");
        c.root = c.pendingRoot;
        c.pendingRoot = bytes32(0);
        emit RootActivated(id, c.root);
    }

    function vetoRoot(uint256 id) external {
        require(msg.sender == guardian, "not guardian");
        Campaign storage c = campaigns[id];
        require(c.pendingRoot != bytes32(0), "nothing pending");
        emit RootVetoed(id, c.pendingRoot);
        c.pendingRoot = bytes32(0);
        c.pendingAt = 0;
    }

    // ------------------------------------------------------------------ creators
    function claim(uint256 id, uint256 cumulativeAmount, bytes32[] calldata proof) external {
        Campaign storage c = campaigns[id];
        bytes32 leaf = keccak256(abi.encodePacked(id, msg.sender, cumulativeAmount));
        require(MerkleProof.verifyCalldata(proof, c.root, leaf), "bad proof");

        uint256 payout = cumulativeAmount - claimed[id][msg.sender];
        require(payout > 0, "nothing to claim");
        c.claimedTotal += payout;
        uint256 amount = _chargeFee(c, payout);
        claimed[id][msg.sender] += amount;
        require(c.token.transfer(msg.sender, amount), "transfer failed");
        emit Paid(id, msg.sender, amount, payout - amount);
    }

    /// @notice Moves a creator's claim record to a new wallet.
    function migrateCreator(uint256 id, address newAddress) external {
        require(newAddress != address(0) && newAddress != msg.sender, "bad address");
        claimed[id][newAddress] += claimed[id][msg.sender];
        claimed[id][msg.sender] = 0;
        emit CreatorMigrated(id, msg.sender, newAddress);
    }

    /// @notice One-off bonus signed by the operator over (chainId, this, campaignId, creator, amount, nonce).
    function redeemVoucher(uint256 id, address creator, uint256 amount, uint256 nonce, bytes calldata signature)
        external
    {
        Campaign storage c = campaigns[id];
        bytes32 sigHash = keccak256(signature);
        require(!usedVouchers[sigHash], "voucher used");

        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19Ethereum Signed Message:\n32",
                keccak256(abi.encode(block.chainid, address(this), id, creator, amount, nonce))
            )
        );
        require(_recover(digest, signature) == operator, "bad signature");
        usedVouchers[sigHash] = true;

        require(c.budget - (c.committed - c.claimedTotal) >= amount, "over budget");
        c.budget -= amount;
        uint256 sent = _chargeFee(c, amount);
        require(c.token.transfer(creator, sent), "transfer failed");
        emit Paid(id, creator, sent, amount - sent);
    }

    /// @dev Accrues the platform fee on `gross` and returns the amount to send.
    function _chargeFee(Campaign storage c, uint256 gross) internal returns (uint256) {
        uint256 fee = (gross * feeBps) / 10_000;
        feesOwed[address(c.token)] += fee;
        return gross - fee;
    }

    function _recover(bytes32 digest, bytes calldata sig) internal pure returns (address) {
        require(sig.length == 65, "bad signature length");
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(sig.offset)
            s := calldataload(add(sig.offset, 32))
            v := byte(0, calldataload(add(sig.offset, 64)))
        }
        if (v < 27) v += 27;
        return ecrecover(digest, v, r, s);
    }
}
