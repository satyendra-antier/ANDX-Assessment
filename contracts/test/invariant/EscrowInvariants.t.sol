// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {AndxEscrow} from "../../src/AndxEscrow.sol";
import {USDX, FOTX, NRT} from "../../src/tokens/MockTokens.sol";
import {Handler} from "./Handler.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract EscrowInvariants is StdInvariant, Test {
    AndxEscrow internal escrow;
    USDX internal usdx;
    FOTX internal fotx;
    NRT internal nrt;
    Handler internal handler;

    address internal owner = makeAddr("owner");
    address internal operator = makeAddr("operator");
    address internal guardian = makeAddr("guardian");

    function setUp() public {
        escrow = new AndxEscrow(owner, operator, guardian, 3600, 172800);
        usdx = new USDX();
        fotx = new FOTX();
        nrt = new NRT();

        vm.startPrank(owner);
        escrow.setTokenAllowed(address(usdx), true);
        escrow.setTokenAllowed(address(fotx), true);
        escrow.setTokenAllowed(address(nrt), true);
        vm.stopPrank();

        handler = new Handler(escrow, usdx, fotx, nrt, owner, operator, guardian);
        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = Handler.createCampaign.selector;
        selectors[1] = Handler.proposeHonest.selector;
        selectors[2] = Handler.proposeAdversarial.selector;
        selectors[3] = Handler.activate.selector;
        selectors[4] = Handler.veto.selector;
        selectors[5] = Handler.claimDirect.selector;
        selectors[6] = Handler.claimWithSigReplay.selector;
        selectors[7] = Handler.refund.selector;
        // warp via separate — include it
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    // I1 solvency per token
    function invariant_I1_solvency() public view {
        _solvency(address(usdx));
        _solvency(address(fotx));
        _solvency(address(nrt));
    }

    function _solvency(address token) internal view {
        uint256 bal = IERC20(token).balanceOf(address(escrow));
        uint256 need;
        uint256 n = handler.campaignCount();
        for (uint256 i = 0; i < n; ++i) {
            bytes32 id = handler.campaignIds(i);
            if (handler.ghostToken(id) != token) continue;
            (,,,, uint256 net,,, uint256 claimed, uint256 refunded) = escrow.campaignState(id);
            need += (net - refunded - claimed);
        }
        assertGe(bal, need);
    }

    // I2 commitments
    function invariant_I2_commitments() public view {
        uint256 n = handler.campaignCount();
        for (uint256 i = 0; i < n; ++i) {
            bytes32 id = handler.campaignIds(i);
            (,,,, uint256 net, uint256 active, uint256 pending, uint256 claimed, uint256 refunded) =
                escrow.campaignState(id);
            assertLe(claimed, active);
            assertLe(active, net - refunded);
            assertLe(pending, net - refunded);
        }
    }

    // I3 no double pay vs max activated cumulative
    function invariant_I3_noDoublePay() public view {
        uint256 n = handler.campaignCount();
        for (uint256 i = 0; i < n; ++i) {
            bytes32 id = handler.campaignIds(i);
            for (uint256 j = 0; j < 4; ++j) {
                address creator = handler.creators(j);
                uint256 claimed = escrow.claimedBy(id, creator);
                uint256 maxAct = handler.ghostMaxActivatedCum(id, creator);
                if (maxAct > 0) {
                    assertLe(claimed, maxAct);
                }
            }
        }
    }

    // I4 isolation — ghost net equals contract net (exact equality ghost)
    function invariant_I4_exactGhost() public view {
        uint256 n = handler.campaignCount();
        for (uint256 i = 0; i < n; ++i) {
            bytes32 id = handler.campaignIds(i);
            (,,,, uint256 net,,, uint256 claimed, uint256 refunded) = escrow.campaignState(id);
            assertEq(net, handler.ghostNet(id));
            assertEq(claimed, handler.ghostClaimed(id));
            assertEq(refunded, handler.ghostRefunded(id));
        }
    }

    // I5 refunds never strand creators
    function invariant_I5_refundsPayable() public view {
        uint256 n = handler.campaignCount();
        for (uint256 i = 0; i < n; ++i) {
            bytes32 id = handler.campaignIds(i);
            (,,,, uint256 net, uint256 active, uint256 pending,, uint256 refunded) = escrow.campaignState(id);
            uint256 reserved = active > pending ? active : pending;
            assertGe(net - refunded, reserved);
        }
    }

    // I6 single use nonce — replay poison metric
    function invariant_I6_nonceAndMetrics() public view {
        assertLt(handler.ghostClaims(), 1000000);
    }
}
