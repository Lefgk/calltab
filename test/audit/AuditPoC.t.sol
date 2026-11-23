// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CallTab} from "../../src/CallTab.sol";
import {MockUSDC} from "../../src/MockUSDC.sol";

/// @notice Audit 2026-11-23 proof-of-concept tests. Each test asserts the SAFE behaviour,
///         so on the pre-fix code the M-* tests fail (issue real) and pass after the fix.
contract AuditPoCTest is Test {
    CallTab internal tab;
    MockUSDC internal usdc;

    uint256 internal constant PAYER_KEY = 0xA11CE;
    uint256 internal constant AGENT_KEY = 0xA6E17;
    uint256 internal constant AGENT2_KEY = 0xA6E18;
    address internal payer;
    address internal agent;
    address internal agent2;
    address internal provider;

    uint64 internal constant WINDOW = 1 hours;
    uint256 internal constant DEPOSIT = 1_000e6;

    function setUp() public {
        usdc = new MockUSDC();
        tab = new CallTab(address(usdc));
        payer = vm.addr(PAYER_KEY);
        agent = vm.addr(AGENT_KEY);
        agent2 = vm.addr(AGENT2_KEY);
        provider = makeAddr("provider");
        usdc.mint(payer, 10_000e6);
        vm.prank(payer);
        usdc.approve(address(tab), type(uint256).max);
    }

    function _open(address agent_, uint256 cap, uint64 dur) internal returns (uint256 id) {
        vm.prank(payer);
        id = tab.openTab(provider, DEPOSIT, cap, dur, 0, WINDOW, agent_, 0, 0);
    }

    function _sig(uint256 key, uint256 id, uint256 cum, uint256 deadline) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, tab.hashVoucher(id, cum, deadline));
        return abi.encodePacked(r, s, v);
    }

    // M-1: payer rotates the agent and voids an agent-signed voucher the provider already holds,
    //      then closes and takes the refund. Safe behaviour: the provider can still redeem it.
    function test_M1_agentRotationCannotVoidHeldVoucher() public {
        uint256 id = _open(agent, 0, 0);
        bytes memory held = _sig(AGENT_KEY, id, 300e6, 0); // provider served 300 USDC of calls

        vm.startPrank(payer);
        tab.setAgent(id, address(0)); // payer "revokes" right after being served
        tab.initiateClose(id);
        vm.stopPrank();

        vm.prank(provider);
        tab.redeem(id, 300e6, 0, held); // pre-fix: reverts BadSignature
        assertEq(usdc.balanceOf(provider), 300e6);
    }

    // M-2: payer pauses until the voucher deadline passes, then closes. Safe behaviour: the
    //      provider gets a challenge window after a pause to redeem what it holds.
    function test_M2_pauseCannotRunOutVoucherDeadline() public {
        uint256 id = _open(address(0), 0, 0);
        uint256 deadline = block.timestamp + 6 hours;
        bytes memory held = _sig(PAYER_KEY, id, 250e6, deadline);

        vm.prank(payer);
        tab.pause(id);

        vm.warp(block.timestamp + 30 minutes); // provider reacts well inside the window
        vm.prank(provider);
        tab.redeem(id, 250e6, deadline, held); // pre-fix: reverts TabPaused (then expires)
        assertEq(usdc.balanceOf(provider), 250e6);
    }

    // M-2 (full grief path, documented): pre-fix the payer wins the whole voucher.
    function test_M2_pauseThenCloseAfterDeadline_providerStillPaidIfActedInWindow() public {
        uint256 id = _open(address(0), 0, 0);
        uint256 deadline = block.timestamp + 2 hours;
        bytes memory held = _sig(PAYER_KEY, id, 250e6, deadline);
        vm.prank(payer);
        tab.pause(id);
        vm.warp(block.timestamp + WINDOW); // last second of the post-pause grace
        vm.prank(provider);
        tab.redeem(id, 250e6, deadline, held);
        assertEq(tab.getTab(id).claimed, 250e6);
    }

    // L-1 check (period cap during Closing is a hard revert, no partial fill): shows behaviour.
    function test_L1_periodCapHardRevertInClosing() public {
        uint256 id = _open(address(0), 100e6, 1 days);
        bytes memory v1 = _sig(PAYER_KEY, id, 90e6, 0);
        vm.prank(provider);
        tab.redeem(id, 90e6, 0, v1);
        bytes memory v2 = _sig(PAYER_KEY, id, 150e6, 0);
        vm.prank(payer);
        tab.initiateClose(id);
        vm.prank(provider);
        vm.expectRevert(abi.encodeWithSelector(CallTab.ExceedsPeriodCap.selector, 60e6, 10e6));
        tab.redeem(id, 150e6, 0, v2);
    }

    // Refuted lead: voucher replay across tabs (tabId is signed).
    function test_refuted_crossTabReplay() public {
        uint256 a = _open(address(0), 0, 0);
        uint256 b = _open(address(0), 0, 0);
        bytes memory s = _sig(PAYER_KEY, a, 10e6, 0);
        vm.prank(provider);
        vm.expectRevert(CallTab.BadSignature.selector);
        tab.redeem(b, 10e6, 0, s);
    }

    // Refuted lead: a voucher can never pay more than its cumulative amount in total.
    function testFuzz_refuted_noOverpayAcrossRedeems(uint96 c1, uint96 c2) public {
        uint256 id = _open(address(0), 0, 0);
        c1 = uint96(bound(c1, 1, DEPOSIT));
        c2 = uint96(bound(c2, c1, 2 * DEPOSIT));
        bytes memory s1 = _sig(PAYER_KEY, id, c1, 0);
        bytes memory s2 = _sig(PAYER_KEY, id, c2, 0);
        vm.prank(provider);
        tab.redeem(id, c1, 0, s1);
        if (c2 > c1) {
            vm.prank(provider);
            try tab.redeem(id, c2, 0, s2) {} catch {}
        }
        assertLe(usdc.balanceOf(provider), c2 < DEPOSIT ? c2 : DEPOSIT);
        vm.prank(provider);
        vm.expectRevert(CallTab.NothingOwed.selector);
        tab.redeem(id, c1, 0, s1);
    }

    // --- regression tests for the M-1 / M-2 fix ---

    function test_fix_oldAgentRevokedAfterGrace() public {
        uint256 id = _open(agent, 0, 0);
        bytes memory held = _sig(AGENT_KEY, id, 100e6, 0);
        vm.prank(payer);
        tab.setAgent(id, agent2);
        assertEq(tab.previousAgent(id), agent);
        assertEq(tab.previousAgentUntil(id), block.timestamp + WINDOW);
        vm.warp(block.timestamp + WINDOW + 1);
        vm.prank(provider);
        vm.expectRevert(CallTab.BadSignature.selector);
        tab.redeem(id, 100e6, 0, held);
        // new agent works immediately
        bytes memory fresh = _sig(AGENT2_KEY, id, 100e6, 0);
        vm.prank(provider);
        tab.redeem(id, 100e6, 0, fresh);
    }

    function test_fix_secondRotationDuringGraceReverts() public {
        uint256 id = _open(agent, 0, 0);
        vm.startPrank(payer);
        tab.setAgent(id, agent2);
        vm.expectRevert(CallTab.AgentRotationPending.selector);
        tab.setAgent(id, address(0));
        vm.warp(block.timestamp + WINDOW + 1);
        tab.setAgent(id, address(0)); // allowed after grace
        vm.stopPrank();
        assertEq(tab.previousAgent(id), agent2);
    }

    function test_fix_rotateViaZeroCannotShortenGrace() public {
        uint256 id = _open(agent, 0, 0);
        bytes memory held = _sig(AGENT_KEY, id, 100e6, 0);
        vm.startPrank(payer);
        tab.setAgent(id, address(0)); // agent -> none: grace starts for `agent`
        tab.setAgent(id, agent2); // none -> agent2: no new grace, `agent` grace kept
        vm.stopPrank();
        assertEq(tab.previousAgent(id), agent);
        vm.prank(provider);
        tab.redeem(id, 100e6, 0, held);
    }

    function test_fix_pauseBitesAfterWindowAndUnpauseResets() public {
        uint256 id = _open(address(0), 0, 0);
        vm.prank(payer);
        tab.pause(id);
        assertEq(tab.pausedAt(id), block.timestamp);
        vm.warp(block.timestamp + WINDOW + 1);
        bytes memory s = _sig(PAYER_KEY, id, 10e6, 0);
        vm.prank(provider);
        vm.expectRevert(CallTab.TabPaused.selector);
        tab.redeem(id, 10e6, 0, s);
        vm.prank(payer);
        tab.unpause(id);
        assertEq(tab.pausedAt(id), 0);
        vm.prank(provider);
        tab.redeem(id, 10e6, 0, s);
    }

    function testFuzz_fix_heldVoucherRedeemableWithinWindowAfterRevocation(uint64 delay, bool viaPause) public {
        delay = uint64(bound(delay, 0, WINDOW));
        uint256 id = _open(agent, 0, 0);
        bytes memory held = _sig(AGENT_KEY, id, 77e6, 0);
        vm.prank(payer);
        if (viaPause) tab.pause(id);
        else tab.setAgent(id, address(0));
        vm.warp(block.timestamp + delay);
        vm.prank(provider);
        tab.redeem(id, 77e6, 0, held);
        assertEq(usdc.balanceOf(provider), 77e6);
    }
}
