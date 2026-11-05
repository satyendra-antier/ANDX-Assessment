// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AndxEscrow} from "../src/AndxEscrow.sol";
import {IAndxEscrow} from "../src/interfaces/IAndxEscrow.sol";
import {HOOK} from "../src/tokens/MockTokens.sol";

/// @dev Malicious recipient that tries to reenter claim on HOOK callback.
contract ReentrantRecipient {
    AndxEscrow public escrow;
    bytes32 public campaignId;
    address public creator;
    uint256 public cumulativeAmount;
    bool public reentered;

    constructor(AndxEscrow e) {
        escrow = e;
    }

    function configure(bytes32 id, address c, uint256 cum) external {
        campaignId = id;
        creator = c;
        cumulativeAmount = cum;
    }

    function register() external {
        // called externally via HOOK.registerHook from this address
    }

    function onTokenReceived(address, uint256) external {
        if (reentered) return;
        reentered = true;
        bytes32[] memory proof = new bytes32[](0);
        IAndxEscrow.Claim memory c =
            IAndxEscrow.Claim({campaignId: campaignId, creator: creator, cumulativeAmount: cumulativeAmount});
        try escrow.claim(c, address(this), proof) {} catch {}
    }
}

contract HookReentrancyTest is Test {
    AndxEscrow internal escrow;
    HOOK internal hook;
    address internal owner = makeAddr("owner");
    address internal operator = makeAddr("operator");
    address internal guardian = makeAddr("guardian");
    address internal brand = makeAddr("brand");
    address internal alice = makeAddr("alice");

    function setUp() public {
        escrow = new AndxEscrow(owner, operator, guardian, 3600, 172800);
        hook = new HOOK();
        vm.prank(owner);
        escrow.setTokenAllowed(address(hook), true);
    }

    function test_hookReentrancyDoesNotBreakAccounting() public {
        ReentrantRecipient recv = new ReentrantRecipient(escrow);
        vm.prank(address(recv));
        hook.registerHook(true);

        uint256 amount = 1_000_000;
        hook.mint(brand, amount);

        vm.startPrank(brand);
        hook.approve(address(escrow), amount);
        bytes32 id =
            escrow.createCampaign(address(hook), amount, uint64(block.timestamp + 7 days), amount, keccak256("hook"));
        vm.stopPrank();

        bytes32 leaf = escrow.leaf(id, alice, 500_000);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        uint256[] memory committed = new uint256[](1);
        committed[0] = 500_000;
        vm.prank(operator);
        escrow.proposeRoot(1, leaf, ids, committed);
        vm.warp(block.timestamp + 3600);
        escrow.activateRoot(1);

        recv.configure(id, alice, 500_000);

        bytes32[] memory proof = new bytes32[](0);
        IAndxEscrow.Claim memory c =
            IAndxEscrow.Claim({campaignId: id, creator: alice, cumulativeAmount: 500_000});
        vm.prank(alice);
        escrow.claim(c, address(recv), proof);

        assertTrue(recv.reentered());
        assertEq(escrow.claimedBy(id, alice), 500_000);
        (,,,,,,, uint256 claimedTotal,) = escrow.campaignState(id);
        assertEq(claimedTotal, 500_000);
    }
}
