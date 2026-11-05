// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AndxEscrow} from "../src/AndxEscrow.sol";
import {IAndxEscrow} from "../src/interfaces/IAndxEscrow.sol";
import {USDX, FOTX, NRT} from "../src/tokens/MockTokens.sol";

contract AndxEscrowTest is Test {
    AndxEscrow internal escrow;
    USDX internal usdx;
    FOTX internal fotx;
    NRT internal nrt;

    address internal owner = makeAddr("owner");
    address internal operator = makeAddr("operator");
    address internal guardian = makeAddr("guardian");
    address internal brand = makeAddr("brand");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint64 internal constant ROOT_DELAY = 3600;
    uint64 internal constant OPERATOR_DELAY = 172800;

    uint256 internal alicePk = 0xA11CE;
    address internal aliceSigner;

    function setUp() public {
        aliceSigner = vm.addr(alicePk);
        alice = aliceSigner;

        escrow = new AndxEscrow(owner, operator, guardian, ROOT_DELAY, OPERATOR_DELAY);
        usdx = new USDX();
        fotx = new FOTX();
        nrt = new NRT();

        vm.startPrank(owner);
        escrow.setTokenAllowed(address(usdx), true);
        escrow.setTokenAllowed(address(fotx), true);
        escrow.setTokenAllowed(address(nrt), true);
        vm.stopPrank();
    }

    function _campaignId(address b, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encode(b, salt));
    }

    function _createUsdx(uint256 amount, bytes32 salt) internal returns (bytes32 id) {
        usdx.mint(brand, amount);
        vm.startPrank(brand);
        usdx.approve(address(escrow), amount);
        id = escrow.createCampaign(address(usdx), amount, uint64(block.timestamp + 7 days), amount, salt);
        vm.stopPrank();
    }

    function _leaf(bytes32 campaignId, address creator, uint256 cum) internal view returns (bytes32) {
        return escrow.leaf(campaignId, creator, cum);
    }

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function test_createCampaign_creditsBalanceDelta_FOTX() public {
        uint256 amount = 500_000_000;
        fotx.mint(brand, amount);
        vm.startPrank(brand);
        fotx.approve(address(escrow), amount);
        bytes32 id = escrow.createCampaign(
            address(fotx), amount, uint64(block.timestamp + 7 days), 120_000_000, keccak256("arcadia-s4")
        );
        vm.stopPrank();

        (,,,, uint256 net,,,,) = escrow.campaignState(id);
        assertEq(net, amount - amount / 100); // 1% burn
        assertEq(fotx.balanceOf(address(escrow)), net);
    }

    function test_createCampaign_NRT_works() public {
        uint256 amount = 300_000_000;
        nrt.mint(brand, amount);
        vm.startPrank(brand);
        nrt.approve(address(escrow), amount);
        bytes32 id =
            escrow.createCampaign(address(nrt), amount, uint64(block.timestamp + 7 days), amount, keccak256("nimbus-nrt"));
        vm.stopPrank();
        (,,,, uint256 net,,,,) = escrow.campaignState(id);
        assertEq(net, amount);
    }

    function test_createCampaign_duplicateReverts() public {
        bytes32 salt = keccak256("dup");
        _createUsdx(1_000_000, salt);
        usdx.mint(brand, 1_000_000);
        vm.startPrank(brand);
        usdx.approve(address(escrow), 1_000_000);
        vm.expectRevert(AndxEscrow.CampaignExists.selector);
        escrow.createCampaign(address(usdx), 1_000_000, uint64(block.timestamp + 1 days), 1, salt);
        vm.stopPrank();
    }

    function test_proposeActivateClaim() public {
        bytes32 id = _createUsdx(1_000_000_000, keccak256("nimbus-swaps"));
        uint256 cum = 300_000_000;
        bytes32 leaf = _leaf(id, alice, cum);
        bytes32 root = leaf; // single-leaf tree

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        uint256[] memory committed = new uint256[](1);
        committed[0] = cum;

        vm.prank(operator);
        escrow.proposeRoot(1, root, ids, committed);

        (uint64 pe,, uint64 activatesAt) = escrow.pendingRoot();
        assertEq(pe, 1);
        vm.warp(activatesAt);
        escrow.activateRoot(1);

        bytes32[] memory proof = new bytes32[](0);
        IAndxEscrow.Claim memory c =
            IAndxEscrow.Claim({campaignId: id, creator: alice, cumulativeAmount: cum});
        uint256 before = usdx.balanceOf(alice);
        vm.prank(alice);
        escrow.claim(c, alice, proof);
        assertEq(usdx.balanceOf(alice) - before, cum);
        assertEq(escrow.claimedBy(id, alice), cum);
    }

    function test_claimWithSig_andReplay() public {
        bytes32 id = _createUsdx(1_000_000_000, keccak256("sig"));
        uint256 cum = 100_000_000;
        bytes32 root = _leaf(id, alice, cum);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        uint256[] memory committed = new uint256[](1);
        committed[0] = cum;
        vm.prank(operator);
        escrow.proposeRoot(1, root, ids, committed);
        vm.warp(block.timestamp + ROOT_DELAY);
        escrow.activateRoot(1);

        IAndxEscrow.ClaimAuth memory auth = IAndxEscrow.ClaimAuth({
            campaignId: id,
            creator: alice,
            cumulativeAmount: cum,
            recipient: alice,
            relayerFee: 0,
            nonce: 7,
            deadline: block.timestamp + 1 days
        });
        bytes32 digest = escrow.hashClaimAuth(auth);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        bytes32[] memory proof = new bytes32[](0);
        address relayer = makeAddr("relayer");
        vm.prank(relayer);
        escrow.claimWithSig(auth, sig, proof);
        assertEq(escrow.claimedBy(id, alice), cum);

        vm.prank(relayer);
        vm.expectRevert(AndxEscrow.NonceUsed.selector);
        escrow.claimWithSig(auth, sig, proof);
    }

    function test_vetoClearsPending_epochStillConsumed() public {
        bytes32 id = _createUsdx(1_000_000, keccak256("veto"));
        bytes32 root = _leaf(id, alice, 100);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        uint256[] memory committed = new uint256[](1);
        committed[0] = 100;
        vm.prank(operator);
        escrow.proposeRoot(1, root, ids, committed);
        vm.prank(guardian);
        escrow.vetoRoot(1);
        (uint64 pe,,) = escrow.pendingRoot();
        assertEq(pe, 0);
        assertEq(escrow.lastEpoch(), 1);

        // next must be epoch 2
        vm.prank(operator);
        escrow.proposeRoot(2, root, ids, committed);
        assertEq(escrow.lastEpoch(), 2);
    }

    function test_refundPreservesCommitments() public {
        bytes32 id = _createUsdx(1_000_000, keccak256("ref"));
        bytes32 root = _leaf(id, alice, 400_000);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        uint256[] memory committed = new uint256[](1);
        committed[0] = 400_000;
        vm.prank(operator);
        escrow.proposeRoot(1, root, ids, committed);
        vm.warp(block.timestamp + ROOT_DELAY);
        escrow.activateRoot(1);

        // end campaign and wait ROOT_DELAY
        (,, uint64 endTime,,,,,,) = escrow.campaignState(id);
        vm.warp(uint256(endTime) + ROOT_DELAY);

        vm.prank(brand);
        uint256 refunded = escrow.refundUnallocated(id);
        assertEq(refunded, 1_000_000 - 400_000);

        vm.prank(brand);
        assertEq(escrow.refundUnallocated(id), 0);
    }

    function test_pendingRootSurvivesRevoke() public {
        bytes32 id = _createUsdx(1_000_000, keccak256("op"));
        bytes32 root = _leaf(id, alice, 100);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        uint256[] memory committed = new uint256[](1);
        committed[0] = 100;
        vm.prank(operator);
        escrow.proposeRoot(1, root, ids, committed);

        vm.prank(guardian);
        escrow.revokeOperator();
        assertEq(escrow.operator(), address(0));

        (uint64 pe, bytes32 pr,) = escrow.pendingRoot();
        assertEq(pe, 1);
        assertEq(pr, root);

        vm.warp(block.timestamp + ROOT_DELAY);
        escrow.activateRoot(1);
        (uint64 ae, bytes32 ar) = escrow.activeRoot();
        assertEq(ae, 1);
        assertEq(ar, root);
    }

    function test_pauseBlocksClaims_allowsVeto() public {
        bytes32 id = _createUsdx(1_000_000, keccak256("pause"));
        bytes32 root = _leaf(id, alice, 100);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        uint256[] memory committed = new uint256[](1);
        committed[0] = 100;
        vm.prank(operator);
        escrow.proposeRoot(1, root, ids, committed);

        vm.prank(guardian);
        escrow.pause();

        vm.prank(guardian);
        escrow.vetoRoot(1);

        vm.prank(owner);
        escrow.unpause();
    }

    function test_commitmentCapAndOrder() public {
        bytes32 id1 = _createUsdx(1_000_000, keccak256("a"));
        bytes32 id2 = _createUsdx(1_000_000, keccak256("b"));
        // force order
        bytes32 lo = uint256(id1) < uint256(id2) ? id1 : id2;
        bytes32 hi = uint256(id1) < uint256(id2) ? id2 : id1;

        bytes32[] memory bad = new bytes32[](2);
        bad[0] = hi;
        bad[1] = lo;
        uint256[] memory c = new uint256[](2);
        c[0] = 1;
        c[1] = 1;
        vm.prank(operator);
        vm.expectRevert(AndxEscrow.BadCampaignOrder.selector);
        escrow.proposeRoot(1, bytes32(uint256(1)), bad, c);

        // epoch cap
        bytes32[] memory one = new bytes32[](1);
        one[0] = id1;
        uint256[] memory over = new uint256[](1);
        (,,, uint256 maxCommit, uint256 net,,,,) = escrow.campaignState(id1);
        over[0] = maxCommit + 1;
        if (over[0] <= net) {
            vm.prank(operator);
            vm.expectRevert(AndxEscrow.ExceedsEpochCap.selector);
            escrow.proposeRoot(1, bytes32(uint256(1)), one, over);
        }
    }

    function test_claimedTotalCannotExceedActiveCommitted() public {
        bytes32 id = _createUsdx(1_000_000, keccak256("over"));
        // root with leaf 900k but commit only 100k
        bytes32 leafA = _leaf(id, alice, 900_000);
        bytes32 root = leafA;
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        uint256[] memory committed = new uint256[](1);
        committed[0] = 100_000;
        vm.prank(operator);
        escrow.proposeRoot(1, root, ids, committed);
        vm.warp(block.timestamp + ROOT_DELAY);
        escrow.activateRoot(1);

        bytes32[] memory proof = new bytes32[](0);
        IAndxEscrow.Claim memory c =
            IAndxEscrow.Claim({campaignId: id, creator: alice, cumulativeAmount: 900_000});
        vm.prank(alice);
        vm.expectRevert(AndxEscrow.ClaimedExceedsCommitted.selector);
        escrow.claim(c, alice, proof);
    }

    function test_claimWithSig_rejectsHighS() public {
        bytes32 id = _createUsdx(1_000_000, keccak256("highs"));
        uint256 cum = 50_000;
        bytes32 root = _leaf(id, alice, cum);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        uint256[] memory committed = new uint256[](1);
        committed[0] = cum;
        vm.prank(operator);
        escrow.proposeRoot(1, root, ids, committed);
        vm.warp(block.timestamp + ROOT_DELAY);
        escrow.activateRoot(1);

        IAndxEscrow.ClaimAuth memory auth = IAndxEscrow.ClaimAuth({
            campaignId: id,
            creator: alice,
            cumulativeAmount: cum,
            recipient: alice,
            relayerFee: 0,
            nonce: 1,
            deadline: block.timestamp + 1 days
        });
        bytes32 digest = escrow.hashClaimAuth(auth);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, digest);
        // Force high-s via secp256k1 malleation (n - s). Contract rejects before ecrecover.
        uint256 secpN = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes32 sHigh = bytes32(secpN - uint256(s));
        uint8 vFlip = v == 27 ? 28 : 27;
        bytes memory badSig = abi.encodePacked(r, sHigh, vFlip);

        bytes32[] memory proof = new bytes32[](0);
        vm.expectRevert(AndxEscrow.BadSignature.selector);
        escrow.claimWithSig(auth, badSig, proof);
    }

    function test_claimWithSig_rejectsGarbageSignature() public {
        bytes32 id = _createUsdx(1_000_000, keccak256("zerosig"));
        uint256 cum = 10_000;
        bytes32 root = _leaf(id, alice, cum);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        uint256[] memory committed = new uint256[](1);
        committed[0] = cum;
        vm.prank(operator);
        escrow.proposeRoot(1, root, ids, committed);
        vm.warp(block.timestamp + ROOT_DELAY);
        escrow.activateRoot(1);

        IAndxEscrow.ClaimAuth memory auth = IAndxEscrow.ClaimAuth({
            campaignId: id,
            creator: alice,
            cumulativeAmount: cum,
            recipient: alice,
            relayerFee: 0,
            nonce: 2,
            deadline: block.timestamp + 1 days
        });
        // 65 zero bytes → ecrecover address(0) / invalid
        bytes memory sig = new bytes(65);
        bytes32[] memory proof = new bytes32[](0);
        vm.expectRevert(AndxEscrow.BadSignature.selector);
        escrow.claimWithSig(auth, sig, proof);
    }

    function test_campaignIsolation() public {
        bytes32 idA = _createUsdx(1_000_000, keccak256("iso-a"));
        bytes32 idB = _createUsdx(2_000_000, keccak256("iso-b"));

        (,,,, uint256 netB0, uint256 actB0,, uint256 claimedB0, uint256 refB0) = escrow.campaignState(idB);

        // Propose+activate+claim only on A
        bytes32 root = _leaf(idA, alice, 100_000);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = idA;
        uint256[] memory committed = new uint256[](1);
        committed[0] = 100_000;
        vm.prank(operator);
        escrow.proposeRoot(1, root, ids, committed);
        vm.warp(block.timestamp + ROOT_DELAY);
        escrow.activateRoot(1);

        bytes32[] memory proof = new bytes32[](0);
        IAndxEscrow.Claim memory c =
            IAndxEscrow.Claim({campaignId: idA, creator: alice, cumulativeAmount: 100_000});
        vm.prank(alice);
        escrow.claim(c, alice, proof);

        (,,,, uint256 netB1, uint256 actB1,, uint256 claimedB1, uint256 refB1) = escrow.campaignState(idB);
        assertEq(netB1, netB0);
        assertEq(actB1, actB0);
        assertEq(claimedB1, claimedB0);
        assertEq(refB1, refB0);
        assertEq(escrow.claimedBy(idB, alice), 0);
    }
}
