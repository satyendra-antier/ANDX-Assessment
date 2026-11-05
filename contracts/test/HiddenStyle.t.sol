// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Scenario tests shaped like brief §10 hidden-suite axes (not their actual suite).
import {Test} from "forge-std/Test.sol";
import {AndxEscrow} from "../src/AndxEscrow.sol";
import {IAndxEscrow} from "../src/interfaces/IAndxEscrow.sol";
import {USDX, HOOK} from "../src/tokens/MockTokens.sol";

contract HiddenStyleTest is Test {
    AndxEscrow internal escrow;
    USDX internal usdx;
    HOOK internal hook;

    address internal owner = makeAddr("owner");
    address internal operator = makeAddr("operator");
    address internal guardian = makeAddr("guardian");
    address internal brand = makeAddr("brand");
    address internal bob = makeAddr("bob");

    uint256 internal alicePk = 0xA11CE;
    address internal alice;

    uint64 internal constant ROOT_DELAY = 3600;
    uint64 internal constant OPERATOR_DELAY = 172800;

    function setUp() public {
        alice = vm.addr(alicePk);
        escrow = new AndxEscrow(owner, operator, guardian, ROOT_DELAY, OPERATOR_DELAY);
        usdx = new USDX();
        hook = new HOOK();

        vm.startPrank(owner);
        escrow.setTokenAllowed(address(usdx), true);
        // HOOK allowlisted here — deploy harness leaves it off; hidden tests turn it on to attack.
        escrow.setTokenAllowed(address(hook), true);
        vm.stopPrank();
    }

    function _id(bytes32 salt) internal view returns (bytes32) {
        return keccak256(abi.encode(brand, salt));
    }

    function _createUsdx(uint256 amount, bytes32 salt) internal returns (bytes32 id) {
        usdx.mint(brand, amount);
        vm.startPrank(brand);
        usdx.approve(address(escrow), amount);
        id = escrow.createCampaign(address(usdx), amount, uint64(block.timestamp + 7 days), amount, salt);
        vm.stopPrank();
    }

    function _proposeActivate(bytes32 id, address creator, uint256 cum, uint256 commit, uint64 epoch) internal {
        bytes32 root = escrow.leaf(id, creator, cum);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        uint256[] memory committed = new uint256[](1);
        committed[0] = commit;
        vm.prank(operator);
        escrow.proposeRoot(epoch, root, ids, committed);
        vm.warp(block.timestamp + ROOT_DELAY);
        escrow.activateRoot(epoch);
    }

    /// @dev Brief §10: weird tokens / HOOK path (allowlisted) — claim succeeds without double-pay.
    function test_hookAllowlisted_createAndClaim() public {
        uint256 amount = 1_000_000;
        hook.mint(brand, amount);
        vm.startPrank(brand);
        hook.approve(address(escrow), amount);
        bytes32 id =
            escrow.createCampaign(address(hook), amount, uint64(block.timestamp + 7 days), amount, keccak256("hook-ok"));
        vm.stopPrank();

        (,,,, uint256 net,,,,) = escrow.campaignState(id);
        assertEq(net, amount);
        assertEq(hook.balanceOf(address(escrow)), amount);

        _proposeActivate(id, alice, 400_000, 400_000, 1);
        bytes32[] memory proof = new bytes32[](0);
        IAndxEscrow.Claim memory c =
            IAndxEscrow.Claim({campaignId: id, creator: alice, cumulativeAmount: 400_000});
        vm.prank(alice);
        escrow.claim(c, alice, proof);
        assertEq(escrow.claimedBy(id, alice), 400_000);
        (,,,,,,, uint256 claimed,) = escrow.campaignState(id);
        assertEq(claimed, 400_000);
    }

    /// @dev Leaves that sum above commitment: second claim hits ClaimedExceedsCommitted.
    function test_leavesSumAboveCommitment_secondClaimReverts() public {
        bytes32 id = _createUsdx(1_000_000, keccak256("over-sum"));
        // Two leaves 600k+600k under one root, but commit only 700k.
        bytes32 leafA = escrow.leaf(id, alice, 600_000);
        bytes32 leafB = escrow.leaf(id, bob, 600_000);
        bytes32 root = leafA < leafB
            ? keccak256(abi.encodePacked(leafA, leafB))
            : keccak256(abi.encodePacked(leafB, leafA));

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        uint256[] memory committed = new uint256[](1);
        committed[0] = 700_000;
        vm.prank(operator);
        escrow.proposeRoot(1, root, ids, committed);
        vm.warp(block.timestamp + ROOT_DELAY);
        escrow.activateRoot(1);

        bytes32[] memory proofA = new bytes32[](1);
        proofA[0] = leafB;
        IAndxEscrow.Claim memory cA =
            IAndxEscrow.Claim({campaignId: id, creator: alice, cumulativeAmount: 600_000});
        vm.prank(alice);
        escrow.claim(cA, alice, proofA);

        bytes32[] memory proofB = new bytes32[](1);
        proofB[0] = leafA;
        IAndxEscrow.Claim memory cB =
            IAndxEscrow.Claim({campaignId: id, creator: bob, cumulativeAmount: 600_000});
        vm.prank(bob);
        vm.expectRevert(AndxEscrow.ClaimedExceedsCommitted.selector);
        escrow.claim(cB, bob, proofB);

        (,,,,,,, uint256 claimed,) = escrow.campaignState(id);
        assertEq(claimed, 600_000);
        assertLe(claimed, 700_000);
    }

    /// @dev Refund must reserve pending commitment (not only active).
    function test_refundReservesPendingCommitment() public {
        bytes32 id = _createUsdx(1_000_000, keccak256("ref-pend"));
        _proposeActivate(id, alice, 200_000, 200_000, 1);

        // Pending root raises commitment to 500k (not yet active).
        bytes32 root2 = escrow.leaf(id, alice, 500_000);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        uint256[] memory committed = new uint256[](1);
        committed[0] = 500_000;
        vm.prank(operator);
        escrow.proposeRoot(2, root2, ids, committed);

        assertEq(escrow.pendingCommitted(id), 500_000);
        (,,,,, uint256 active,,,) = escrow.campaignState(id);
        assertEq(active, 200_000);

        vm.warp(block.timestamp + 7 days + ROOT_DELAY);
        vm.prank(brand);
        uint256 got = escrow.refundUnallocated(id);
        // net 1e6 - max(active 200k, pending 500k) = 500k
        assertEq(got, 500_000);
        (,,,,,,,, uint256 refunded) = escrow.campaignState(id);
        assertEq(refunded, 500_000);

        // Pending can still activate and be claimed afterward.
        escrow.activateRoot(2);
        bytes32[] memory proof = new bytes32[](0);
        IAndxEscrow.Claim memory c =
            IAndxEscrow.Claim({campaignId: id, creator: alice, cumulativeAmount: 500_000});
        vm.prank(alice);
        escrow.claim(c, alice, proof);
        assertEq(escrow.claimedBy(id, alice), 500_000);
    }

    /// @dev After endTime, commitment cannot increase.
    function test_proposeCannotIncreaseAfterEndTime() public {
        bytes32 id = _createUsdx(1_000_000, keccak256("ended"));
        _proposeActivate(id, alice, 100_000, 100_000, 1);

        (,, uint64 endTime,,,,,,) = escrow.campaignState(id);
        vm.warp(uint256(endTime) + 1);

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        uint256[] memory committed = new uint256[](1);
        committed[0] = 200_000;
        vm.prank(operator);
        vm.expectRevert(AndxEscrow.CampaignEnded.selector);
        escrow.proposeRoot(2, bytes32(uint256(2)), ids, committed);
    }

    /// @dev Vetoed epoch still consumed — next propose must use epoch+1.
    function test_vetoConsumesEpoch_nextMustIncrement() public {
        bytes32 id = _createUsdx(1_000_000, keccak256("ep"));
        bytes32 root = escrow.leaf(id, alice, 50_000);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        uint256[] memory committed = new uint256[](1);
        committed[0] = 50_000;
        vm.prank(operator);
        escrow.proposeRoot(1, root, ids, committed);
        assertEq(escrow.lastEpoch(), 1);

        vm.prank(guardian);
        escrow.vetoRoot(1);

        vm.prank(operator);
        vm.expectRevert(AndxEscrow.EpochInvalid.selector);
        escrow.proposeRoot(1, root, ids, committed);

        vm.prank(operator);
        escrow.proposeRoot(2, root, ids, committed);
        assertEq(escrow.lastEpoch(), 2);
    }

    /// @dev EIP-712 domain binds to escrow address — sig for A fails on B.
    function test_claimWithSig_rejectsCrossContractReplay() public {
        bytes32 id = _createUsdx(1_000_000, keccak256("xplay"));
        _proposeActivate(id, alice, 80_000, 80_000, 1);

        AndxEscrow other = new AndxEscrow(owner, operator, guardian, ROOT_DELAY, OPERATOR_DELAY);
        vm.prank(owner);
        other.setTokenAllowed(address(usdx), true);

        IAndxEscrow.ClaimAuth memory auth = IAndxEscrow.ClaimAuth({
            campaignId: id,
            creator: alice,
            cumulativeAmount: 80_000,
            recipient: alice,
            relayerFee: 0,
            nonce: 9,
            deadline: block.timestamp + 1 days
        });
        // Sign digest for *this* escrow
        bytes32 digest = escrow.hashClaimAuth(auth);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);
        bytes32[] memory proof = new bytes32[](0);

        // Submitting to a different escrow must fail (domain separator differs).
        vm.expectRevert(AndxEscrow.BadSignature.selector);
        other.claimWithSig(auth, sig, proof);

        // Original still works once.
        escrow.claimWithSig(auth, sig, proof);
        assertEq(escrow.claimedBy(id, alice), 80_000);
    }

    /// @dev Pause blocks claims; veto still works (emergency matrix).
    function test_pauseBlocksClaim_allowsVetoPending() public {
        bytes32 id = _createUsdx(1_000_000, keccak256("pause2"));
        bytes32 root = escrow.leaf(id, alice, 10_000);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        uint256[] memory committed = new uint256[](1);
        committed[0] = 10_000;
        vm.prank(operator);
        escrow.proposeRoot(1, root, ids, committed);

        vm.prank(guardian);
        escrow.pause();

        vm.warp(block.timestamp + ROOT_DELAY);
        vm.expectRevert(AndxEscrow.PausedError.selector);
        escrow.activateRoot(1);

        vm.prank(guardian);
        escrow.vetoRoot(1);
        (uint64 pe,,) = escrow.pendingRoot();
        assertEq(pe, 0);
    }

    /// @dev Pending survives applyOperator (4.5 twin of revoke test).
    function test_pendingRootSurvivesApplyOperator() public {
        bytes32 id = _createUsdx(1_000_000, keccak256("rot"));
        bytes32 root = escrow.leaf(id, alice, 25_000);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        uint256[] memory committed = new uint256[](1);
        committed[0] = 25_000;
        vm.prank(operator);
        escrow.proposeRoot(1, root, ids, committed);

        address nextOp = makeAddr("nextOp");
        vm.prank(owner);
        escrow.queueOperator(nextOp);
        vm.warp(block.timestamp + OPERATOR_DELAY);
        escrow.applyOperator();
        assertEq(escrow.operator(), nextOp);

        (uint64 pe, bytes32 pr,) = escrow.pendingRoot();
        assertEq(pe, 1);
        assertEq(pr, root);

        escrow.activateRoot(1);
        (uint64 ae, bytes32 ar) = escrow.activeRoot();
        assertEq(ae, 1);
        assertEq(ar, root);
    }

    function test_refundTooEarlyReverts() public {
        bytes32 id = _createUsdx(1_000_000, keccak256("early"));
        vm.prank(brand);
        vm.expectRevert(AndxEscrow.TooEarly.selector);
        escrow.refundUnallocated(id);
    }
}
