// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CallTab} from "../src/CallTab.sol";
import {MockUSDC} from "../src/MockUSDC.sol";

contract CallTabTest is Test {
    CallTab internal tab;
    MockUSDC internal usdc;

    uint256 internal payerKey;
    uint256 internal agentKey;
    uint256 internal otherKey;
    address internal payer;
    address internal agent;
    address internal provider;
    address internal other;
    address internal stranger;

    uint64 internal constant WINDOW = 1 hours;
    uint256 internal constant DEPOSIT = 1_000e6;

    function setUp() public {
        usdc = new MockUSDC();
        tab = new CallTab(address(usdc));

        payerKey = 0xA11CE;
        agentKey = 0xA6E17;
        otherKey = 0xB0B;
        payer = vm.addr(payerKey);
        agent = vm.addr(agentKey);
        other = vm.addr(otherKey);
        provider = makeAddr("provider");
        stranger = makeAddr("stranger");

        usdc.mint(payer, 10_000e6);
        usdc.mint(other, 10_000e6);
        vm.prank(payer);
        usdc.approve(address(tab), type(uint256).max);
        vm.prank(other);
        usdc.approve(address(tab), type(uint256).max);
    }

    function _open(uint256 amount, uint256 periodCap, uint64 periodDuration, uint64 expiry, address agent_)
        internal
        returns (uint256 id)
    {
        vm.prank(payer);
        id = tab.openTab(provider, amount, periodCap, periodDuration, expiry, WINDOW, agent_, 0, 0);
    }

    function _openDefault() internal returns (uint256) {
        return _open(DEPOSIT, 0, 0, 0, address(0));
    }

    function _sign(uint256 key, uint256 tabId, uint256 cumulative, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = tab.hashVoucher(tabId, cumulative, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _redeem(uint256 tabId, uint256 cumulative, uint256 deadline, uint256 key) internal {
        bytes memory sig = _sign(key, tabId, cumulative, deadline);
        vm.prank(provider);
        tab.redeem(tabId, cumulative, deadline, sig);
    }

    // --- open ---

    function test_constructorRejectsZeroUsdc() public {
        vm.expectRevert(CallTab.ZeroAddress.selector);
        new CallTab(address(0));
    }

    function test_openTabStoresParamsAndPullsUsdc() public {
        uint64 expiry = uint64(block.timestamp + 30 days);
        vm.prank(payer);
        uint256 id = tab.openTab(provider, DEPOSIT, 25e6, 1 days, expiry, WINDOW, agent, 11, 22);
        assertEq(id, 1);
        CallTab.Tab memory t = tab.getTab(id);
        assertEq(t.payer, payer);
        assertEq(t.provider, provider);
        assertEq(t.agent, agent);
        assertEq(t.deposited, DEPOSIT);
        assertEq(t.claimed, 0);
        assertEq(t.refunded, 0);
        assertEq(t.periodCap, 25e6);
        assertEq(t.periodDuration, 1 days);
        assertEq(t.expiry, expiry);
        assertEq(t.challengeWindow, WINDOW);
        assertEq(uint8(t.status), uint8(CallTab.Status.Open));
        assertFalse(t.paused);
        assertEq(t.payerAgentId, 11);
        assertEq(t.providerAgentId, 22);
        assertEq(tab.remaining(id), DEPOSIT);
        assertEq(usdc.balanceOf(address(tab)), DEPOSIT);
        assertEq(usdc.balanceOf(payer), 10_000e6 - DEPOSIT);
        assertEq(tab.tabsOfPayer(payer).length, 1);
        assertEq(tab.tabsOfProvider(provider)[0], 1);
        assertEq(tab.nextTabId(), 2);
    }

    function test_openTabRevertsOnBadParams() public {
        vm.startPrank(payer);
        vm.expectRevert(CallTab.ZeroAddress.selector);
        tab.openTab(address(0), DEPOSIT, 0, 0, 0, WINDOW, address(0), 0, 0);
        vm.expectRevert(CallTab.SelfTab.selector);
        tab.openTab(payer, DEPOSIT, 0, 0, 0, WINDOW, address(0), 0, 0);
        vm.expectRevert(CallTab.ZeroAmount.selector);
        tab.openTab(provider, 0, 0, 0, 0, WINDOW, address(0), 0, 0);
        vm.expectRevert(CallTab.InvalidPeriod.selector);
        tab.openTab(provider, DEPOSIT, 1, 0, 0, WINDOW, address(0), 0, 0);
        vm.expectRevert(CallTab.InvalidPeriod.selector);
        tab.openTab(provider, DEPOSIT, 0, 1 days, 0, WINDOW, address(0), 0, 0);
        vm.expectRevert(CallTab.InvalidExpiry.selector);
        tab.openTab(provider, DEPOSIT, 0, 0, uint64(block.timestamp), WINDOW, address(0), 0, 0);
        vm.expectRevert(CallTab.InvalidChallengeWindow.selector);
        tab.openTab(provider, DEPOSIT, 0, 0, 0, WINDOW - 1, address(0), 0, 0);
        vm.expectRevert(CallTab.InvalidChallengeWindow.selector);
        tab.openTab(provider, DEPOSIT, 0, 0, 0, 7 days + 1, address(0), 0, 0);
        vm.stopPrank();
    }

    // --- top up / agent ---

    function test_topUpIncreasesRemaining() public {
        uint256 id = _openDefault();
        vm.prank(payer);
        tab.topUp(id, 50e6);
        assertEq(tab.remaining(id), DEPOSIT + 50e6);
        assertEq(tab.getTab(id).deposited, DEPOSIT + 50e6);
    }

    function test_topUpOnlyPayerAndOnlyWhenOpen() public {
        uint256 id = _openDefault();
        vm.prank(stranger);
        vm.expectRevert(CallTab.NotPayer.selector);
        tab.topUp(id, 1);
        vm.prank(payer);
        tab.initiateClose(id);
        vm.prank(payer);
        vm.expectRevert(CallTab.NotOpen.selector);
        tab.topUp(id, 1);
    }

    function test_setAgentOnlyPayer() public {
        uint256 id = _openDefault();
        vm.prank(payer);
        tab.setAgent(id, agent);
        assertEq(tab.getTab(id).agent, agent);
        vm.prank(stranger);
        vm.expectRevert(CallTab.NotPayer.selector);
        tab.setAgent(id, address(0));
    }

    function test_unknownTabReverts() public {
        assertEq(tab.getTab(99).payer, address(0));
        vm.prank(provider);
        vm.expectRevert(CallTab.UnknownTab.selector);
        tab.redeem(99, 1, 0, hex"00");
    }

    // --- redeem / vouchers ---

    function test_redeemPaysDeltaOnly() public {
        uint256 id = _openDefault();
        _redeem(id, 100e6, 0, payerKey);
        assertEq(usdc.balanceOf(provider), 100e6);
        assertEq(tab.getTab(id).claimed, 100e6);
        assertEq(tab.remaining(id), 900e6);

        _redeem(id, 250e6, 0, payerKey);
        assertEq(usdc.balanceOf(provider), 250e6);
        assertEq(tab.getTab(id).claimed, 250e6);
        assertEq(tab.remaining(id), 750e6);
    }

    function test_replaySameOrLowerVoucherReverts() public {
        uint256 id = _openDefault();
        _redeem(id, 100e6, 0, payerKey);
        bytes memory sameSig = _sign(payerKey, id, 100e6, 0);
        bytes memory lowerSig = _sign(payerKey, id, 40e6, 0);
        vm.prank(provider);
        vm.expectRevert(CallTab.NothingOwed.selector);
        tab.redeem(id, 100e6, 0, sameSig);
        vm.prank(provider);
        vm.expectRevert(CallTab.NothingOwed.selector);
        tab.redeem(id, 40e6, 0, lowerSig);
    }

    function test_redeemCapsAtDeposit() public {
        uint256 id = _open(100e6, 0, 0, 0, address(0));
        _redeem(id, 250e6, 0, payerKey);
        assertEq(usdc.balanceOf(provider), 100e6);
        assertEq(tab.getTab(id).claimed, 100e6);
        assertEq(tab.remaining(id), 0);
        // no more funds even with a higher voucher
        vm.prank(payer);
        tab.topUp(id, 10e6);
        _redeem(id, 250e6, 0, payerKey);
        assertEq(usdc.balanceOf(provider), 110e6);
    }

    function test_voucherFromOtherTabDoesNotReplay() public {
        uint256 a = _openDefault();
        vm.prank(payer);
        uint256 b = tab.openTab(provider, DEPOSIT, 0, 0, 0, WINDOW, address(0), 0, 0);
        bytes memory sigA = _sign(payerKey, a, 100e6, 0);
        vm.prank(provider);
        vm.expectRevert(CallTab.BadSignature.selector);
        tab.redeem(b, 100e6, 0, sigA);
        // original tab still works once
        vm.prank(provider);
        tab.redeem(a, 100e6, 0, sigA);
        assertEq(tab.getTab(a).claimed, 100e6);
        assertEq(tab.getTab(b).claimed, 0);
    }

    function test_wrongChainDomainRejected() public {
        uint256 id = _openDefault();
        bytes32 digest = tab.hashVoucher(id, 100e6, 0);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(payerKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        // After a chain-id change the contract's EIP-712 domain changes, so the old sig fails.
        vm.chainId(8453);
        vm.prank(provider);
        vm.expectRevert(CallTab.BadSignature.selector);
        tab.redeem(id, 100e6, 0, sig);
    }

    function test_strangerSignatureRejected() public {
        uint256 id = _openDefault();
        bytes memory sig = _sign(otherKey, id, 10e6, 0);
        vm.prank(provider);
        vm.expectRevert(CallTab.BadSignature.selector);
        tab.redeem(id, 10e6, 0, sig);
    }

    function test_onlyProviderCanRedeem() public {
        uint256 id = _openDefault();
        bytes memory sig = _sign(payerKey, id, 10e6, 0);
        vm.prank(stranger);
        vm.expectRevert(CallTab.NotProvider.selector);
        tab.redeem(id, 10e6, 0, sig);
    }

    function test_agentSignatureWorksAndRotationRevokesOld() public {
        uint256 id = _open(DEPOSIT, 0, 0, 0, agent);
        _redeem(id, 10e6, 0, agentKey);
        assertEq(tab.getTab(id).claimed, 10e6);

        // payer signature still works
        _redeem(id, 20e6, 0, payerKey);
        assertEq(tab.getTab(id).claimed, 20e6);

        vm.prank(payer);
        tab.setAgent(id, other);
        // audit M-1: the old agent keeps a one-window grace, then is revoked
        vm.warp(block.timestamp + WINDOW + 1);
        bytes memory oldAgentSig = _sign(agentKey, id, 30e6, 0);
        vm.prank(provider);
        vm.expectRevert(CallTab.BadSignature.selector);
        tab.redeem(id, 30e6, 0, oldAgentSig);
        _redeem(id, 30e6, 0, otherKey);
        assertEq(tab.getTab(id).claimed, 30e6);
    }

    function test_voucherDeadline() public {
        uint256 id = _openDefault();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(payerKey, id, 10e6, deadline);
        vm.warp(deadline + 1);
        vm.prank(provider);
        vm.expectRevert(CallTab.VoucherExpired.selector);
        tab.redeem(id, 10e6, deadline, sig);
        // deadline 0 never expires
        _redeem(id, 10e6, 0, payerKey);
        assertEq(tab.getTab(id).claimed, 10e6);
    }

    // --- pause ---

    function test_pauseBlocksRedeemUntilUnpause() public {
        uint256 id = _openDefault();
        vm.prank(payer);
        tab.pause(id);
        // audit M-2: pause bites only after the challenge window
        vm.warp(block.timestamp + WINDOW + 1);
        bytes memory sig = _sign(payerKey, id, 10e6, 0);
        vm.prank(provider);
        vm.expectRevert(CallTab.TabPaused.selector);
        tab.redeem(id, 10e6, 0, sig);
        vm.prank(payer);
        tab.unpause(id);
        _redeem(id, 10e6, 0, payerKey);
        assertEq(tab.getTab(id).claimed, 10e6);
    }

    function test_pauseIdempotenceAndAuth() public {
        uint256 id = _openDefault();
        vm.prank(stranger);
        vm.expectRevert(CallTab.NotPayer.selector);
        tab.pause(id);
        vm.startPrank(payer);
        tab.pause(id);
        vm.expectRevert(CallTab.AlreadyPaused.selector);
        tab.pause(id);
        tab.unpause(id);
        vm.expectRevert(CallTab.NotPaused.selector);
        tab.unpause(id);
        vm.stopPrank();
    }

    // --- close / challenge ---

    function test_closeChallengeThenRefund() public {
        uint256 id = _openDefault();
        _redeem(id, 200e6, 0, payerKey);

        vm.prank(payer);
        tab.pause(id); // pause must not block the challenge redeem
        vm.prank(payer);
        tab.initiateClose(id);

        _redeem(id, 350e6, 0, payerKey);
        assertEq(usdc.balanceOf(provider), 350e6);

        vm.expectRevert(CallTab.WindowOpen.selector);
        tab.finalizeClose(id);

        vm.warp(block.timestamp + WINDOW + 1);
        bytes memory lateSig = _sign(payerKey, id, 400e6, 0);
        vm.prank(provider);
        vm.expectRevert(CallTab.WindowClosed.selector);
        tab.redeem(id, 400e6, 0, lateSig);

        uint256 payerBefore = usdc.balanceOf(payer);
        // anyone may finalize
        vm.prank(stranger);
        tab.finalizeClose(id);
        assertEq(usdc.balanceOf(payer), payerBefore + (DEPOSIT - 350e6));
        assertEq(tab.remaining(id), 0);
        assertEq(uint8(tab.getTab(id).status), uint8(CallTab.Status.Closed));
        assertEq(tab.getTab(id).claimed, 350e6);
        assertEq(tab.getTab(id).refunded, DEPOSIT - 350e6);

        vm.prank(payer);
        vm.expectRevert(CallTab.NotOpen.selector);
        tab.topUp(id, 1);
        vm.prank(provider);
        vm.expectRevert(CallTab.NotOpen.selector);
        tab.redeem(id, 400e6, 0, lateSig);
    }

    function test_initiateCloseOnlyPayerWhenOpen() public {
        uint256 id = _openDefault();
        vm.prank(stranger);
        vm.expectRevert(CallTab.NotPayer.selector);
        tab.initiateClose(id);
        vm.prank(payer);
        tab.initiateClose(id);
        vm.prank(payer);
        vm.expectRevert(CallTab.NotOpen.selector);
        tab.initiateClose(id);
    }

    // --- period cap ---

    function test_periodCapHardRevertThenRolls() public {
        uint256 id = _open(DEPOSIT, 25e6, 1 days, 0, address(0));
        _redeem(id, 20e6, 0, payerKey);
        bytes memory capSig = _sign(payerKey, id, 30e6, 0);
        vm.prank(provider);
        vm.expectRevert(abi.encodeWithSelector(CallTab.ExceedsPeriodCap.selector, 10e6, 5e6));
        tab.redeem(id, 30e6, 0, capSig);
        _redeem(id, 25e6, 0, payerKey);
        assertEq(tab.getTab(id).claimed, 25e6);

        vm.warp(block.timestamp + 1 days);
        _redeem(id, 50e6, 0, payerKey);
        assertEq(tab.getTab(id).claimed, 50e6);
        assertEq(tab.getTab(id).periodSpent, 25e6);
    }

    function test_zeroPeriodCapMeansUnlimited() public {
        uint256 id = _openDefault();
        _redeem(id, DEPOSIT, 0, payerKey);
        assertEq(tab.getTab(id).claimed, DEPOSIT);
    }

    // --- accounting fuzz ---

    function testFuzz_neverPayMoreThanVoucherOrDeposit(uint256 deposit, uint256 first, uint256 second) public {
        deposit = bound(deposit, 1, 5_000e6);
        first = bound(first, 1, 10_000e6);
        second = bound(second, first, 10_000e6);

        uint256 id = _open(deposit, 0, 0, 0, address(0));
        _redeem(id, first, 0, payerKey);
        uint256 paid1 = tab.getTab(id).claimed;
        assertLe(paid1, first);
        assertLe(paid1, deposit);

        if (second > paid1 && tab.remaining(id) > 0) {
            _redeem(id, second, 0, payerKey);
        }
        uint256 paid = tab.getTab(id).claimed;
        assertLe(paid, second);
        assertLe(paid, deposit);
        assertEq(paid, usdc.balanceOf(provider));
        assertEq(tab.remaining(id) + paid, deposit);
        assertEq(usdc.balanceOf(address(tab)), tab.remaining(id));
    }

    function testFuzz_openAndRemaining(uint96 amount, uint32 windowExtra) public {
        amount = uint96(bound(amount, 1, 5_000e6));
        uint64 window = uint64(bound(windowExtra, WINDOW, 7 days));
        vm.prank(payer);
        uint256 id = tab.openTab(provider, amount, 0, 0, 0, window, address(0), 0, 0);
        assertEq(tab.remaining(id), amount);
        assertEq(usdc.balanceOf(address(tab)), amount);
    }
}
