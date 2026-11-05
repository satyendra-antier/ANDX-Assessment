// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Required interface for AndxEscrow. Implement it exactly.
/// Our hidden tests deploy your contract with:
///   deployCode("AndxEscrow.sol:AndxEscrow", abi.encode(owner, operator, guardian, rootDelay, operatorDelay))
/// and then talk to it only through this interface.
///
/// Constructor (required, in this order):
///   constructor(address owner_, address operator_, address guardian_, uint64 rootDelay_, uint64 operatorDelay_)
interface IAndxEscrow {
    struct Claim {
        bytes32 campaignId;
        address creator;
        uint256 cumulativeAmount;
    }

    struct ClaimAuth {
        bytes32 campaignId;
        address creator;
        uint256 cumulativeAmount;
        address recipient;
        uint256 relayerFee;
        uint256 nonce;
        uint256 deadline;
    }

    // ---------------------------------------------------------------------
    // Events (emit exactly these; your indexer and ours depend on them)
    // ---------------------------------------------------------------------
    event CampaignCreated(
        bytes32 indexed campaignId,
        address indexed brand,
        address indexed token,
        uint64 endTime,
        uint256 maxCommitPerEpoch,
        uint256 received
    );
    event RootProposed(
        uint64 indexed epoch, bytes32 root, uint64 activatesAt, bytes32[] campaignIds, uint256[] newCommitted
    );
    event RootVetoed(uint64 indexed epoch);
    event RootActivated(uint64 indexed epoch, bytes32 root);
    event Claimed(
        bytes32 indexed campaignId,
        address indexed creator,
        address indexed recipient,
        uint256 cumulativeAmount,
        uint256 paid,
        uint256 relayerFee
    );
    event Refunded(bytes32 indexed campaignId, address indexed brand, uint256 amount);
    event OperatorQueued(address indexed newOperator, uint64 effectiveAt);
    event OperatorChanged(address indexed oldOperator, address indexed newOperator);
    event OperatorRevoked(address indexed oldOperator);
    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event TokenAllowed(address indexed token, bool allowed);

    // ---------------------------------------------------------------------
    // Brands
    // ---------------------------------------------------------------------
    function createCampaign(address token, uint256 amount, uint64 endTime, uint256 maxCommitPerEpoch, bytes32 salt)
        external
        returns (bytes32 campaignId);

    function refundUnallocated(bytes32 campaignId) external returns (uint256 amount);

    // ---------------------------------------------------------------------
    // Operator, guardian, owner
    // ---------------------------------------------------------------------
    function proposeRoot(uint64 epoch, bytes32 root, bytes32[] calldata campaignIds, uint256[] calldata newCommitted)
        external;
    function activateRoot(uint64 epoch) external;
    function vetoRoot(uint64 epoch) external;

    function queueOperator(address newOperator) external;
    function applyOperator() external;
    function revokeOperator() external;

    function pause() external;
    function unpause() external;
    function setTokenAllowed(address token, bool allowed) external;

    // ---------------------------------------------------------------------
    // Creators and relayers
    // ---------------------------------------------------------------------
    function claim(Claim calldata c, address recipient, bytes32[] calldata proof) external;
    function claimWithSig(ClaimAuth calldata auth, bytes calldata signature, bytes32[] calldata proof) external;

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------
    function campaignState(bytes32 campaignId)
        external
        view
        returns (
            address brand,
            address token,
            uint64 endTime,
            uint256 maxCommitPerEpoch,
            uint256 netDeposited,
            uint256 activeCommitted,
            uint256 pendingCommitted,
            uint256 claimedTotal,
            uint256 refunded
        );

    function claimedBy(bytes32 campaignId, address creator) external view returns (uint256);
    function activeRoot() external view returns (uint64 epoch, bytes32 root);
    function pendingRoot() external view returns (uint64 epoch, bytes32 root, uint64 activatesAt);
    function lastEpoch() external view returns (uint64);

    function owner() external view returns (address);
    function operator() external view returns (address);
    function guardian() external view returns (address);
    function queuedOperator() external view returns (address newOperator, uint64 effectiveAt);
    function paused() external view returns (bool);
    function tokenAllowed(address token) external view returns (bool);
    function ROOT_DELAY() external view returns (uint64);
    function OPERATOR_DELAY() external view returns (uint64);

    function nonceUsed(address creator, uint256 nonce) external view returns (bool);
    function hashClaimAuth(ClaimAuth calldata auth) external view returns (bytes32);
    function leaf(bytes32 campaignId, address creator, uint256 cumulativeAmount) external view returns (bytes32);
}
