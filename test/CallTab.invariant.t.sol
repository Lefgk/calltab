// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CallTab} from "../src/CallTab.sol";
import {MockUSDC} from "../src/MockUSDC.sol";

contract CallTabHandler is Test {
    CallTab public tab;
    MockUSDC public usdc;

    uint256 public constant PAYER_KEY = 0xA11CE;
    uint256 public constant AGENT_KEY = 0xA6E17;
    address public payer;
    address public agent;
    address public provider;
    address public stranger;

    uint256 public ghostClaimed;
    uint256 public ghostRefunded;
    uint256 public ghostDeposited;
    mapping(uint256 => uint256) public ghostMaxVoucher;

    constructor(CallTab tab_, MockUSDC usdc_) {
        tab = tab_;
        usdc = usdc_;
        payer = vm.addr(PAYER_KEY);
        agent = vm.addr(AGENT_KEY);
        provider = makeAddr("inv-provider");
        stranger = makeAddr("inv-stranger");
        usdc.mint(payer, 1_000_000e6);
        vm.prank(payer);
        usdc.approve(address(tab), type(uint256).max);
    }

    function openTab(uint256 amount, uint256 periodSeed, uint64 windowSeed, bool withAgent) external {
        amount = bound(amount, 1e6, 10_000e6);
        if (usdc.balanceOf(payer) < amount) return;
        uint256 periodCap;
        uint64 periodDuration;
        if (periodSeed % 3 == 0) {
            periodCap = bound(periodSeed, 1e6, amount);
            periodDuration = 1 days;
        }
        uint64 window = uint64(bound(windowSeed, 1 hours, 7 days));
        vm.prank(payer);
        try tab.openTab(
            provider,
            amount,
            periodCap,
            periodDuration,
            0,
            window,
            withAgent ? agent : address(0),
            0,
            0
        ) {
            ghostDeposited += amount;
        } catch {}
    }

    function topUp(uint256 tabIdx, uint256 amount) external {
        uint256 id = _id(tabIdx);
        if (id == 0) return;
        amount = bound(amount, 1e6, 5_000e6);
        if (usdc.balanceOf(payer) < amount) return;
        vm.prank(payer);
        try tab.topUp(id, amount) {
            ghostDeposited += amount;
        } catch {}
    }

    function setAgent(uint256 tabIdx, bool on) external {
        uint256 id = _id(tabIdx);
        if (id == 0) return;
        vm.prank(payer);
        try tab.setAgent(id, on ? agent : address(0)) {} catch {}
    }

    function pause(uint256 tabIdx) external {
        uint256 id = _id(tabIdx);
        if (id == 0) return;
        vm.prank(payer);
        try tab.pause(id) {} catch {}
    }

    function unpause(uint256 tabIdx) external {
        uint256 id = _id(tabIdx);
        if (id == 0) return;
        vm.prank(payer);
        try tab.unpause(id) {} catch {}
    }

    function redeem(uint256 tabIdx, uint256 extra, bool useAgent, uint256 deadlineSeed) external {
        uint256 id = _id(tabIdx);
        if (id == 0) return;
        CallTab.Tab memory t = tab.getTab(id);
        extra = bound(extra, 1, 5_000e6);
        uint256 cumulative = t.claimed + extra;
        uint256 deadline = deadlineSeed % 5 == 0 ? block.timestamp + 7 days : 0;
        uint256 claimedBefore = t.claimed;
        uint256 remBefore = t.deposited - t.claimed - t.refunded;
        bytes memory sig = _sig(useAgent ? AGENT_KEY : PAYER_KEY, id, cumulative, deadline);
        vm.prank(provider);
        try tab.redeem(id, cumulative, deadline, sig) {
            _book(id, claimedBefore, remBefore, extra, cumulative);
        } catch {}
    }

    function _sig(uint256 key, uint256 id, uint256 cumulative, uint256 deadline) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, tab.hashVoucher(id, cumulative, deadline));
        return abi.encodePacked(r, s, v);
    }

    function _book(uint256 id, uint256 claimedBefore, uint256 remBefore, uint256 extra, uint256 cumulative) internal {
        uint256 paid = tab.getTab(id).claimed - claimedBefore;
        ghostClaimed += paid;
        if (cumulative > ghostMaxVoucher[id]) ghostMaxVoucher[id] = cumulative;
        assertLe(paid, extra);
        assertLe(paid, remBefore);
    }

    function initiateClose(uint256 tabIdx) external {
        uint256 id = _id(tabIdx);
        if (id == 0) return;
        vm.prank(payer);
        try tab.initiateClose(id) {} catch {}
    }

    function warpAndFinalize(uint256 tabIdx, uint256 warpSeed) external {
        uint256 id = _id(tabIdx);
        if (id == 0) return;
        CallTab.Tab memory t = tab.getTab(id);
        if (t.status != CallTab.Status.Closing) return;
        uint256 eta = uint256(t.closeInitiatedAt) + uint256(t.challengeWindow) + 1;
        if (block.timestamp < eta) {
            vm.warp(eta + bound(warpSeed, 0, 3 days));
        }
        uint256 rem = t.deposited - t.claimed - t.refunded;
        try tab.finalizeClose(id) {
            ghostRefunded += rem;
        } catch {}
    }

    function _id(uint256 tabIdx) internal view returns (uint256) {
        uint256 n = tab.nextTabId();
        if (n <= 1) return 0;
        return bound(tabIdx, 1, n - 1);
    }
}

contract CallTabInvariantTest is Test {
    CallTab internal tab;
    MockUSDC internal usdc;
    CallTabHandler internal handler;

    function setUp() public {
        usdc = new MockUSDC();
        tab = new CallTab(address(usdc));
        handler = new CallTabHandler(tab, usdc);
        targetContract(address(handler));
    }

    function invariant_contractBalanceEqualsOutstanding() public view {
        uint256 outstanding;
        uint256 n = tab.nextTabId();
        for (uint256 id = 1; id < n; id++) {
            outstanding += tab.remaining(id);
        }
        assertEq(usdc.balanceOf(address(tab)), outstanding);
    }

    function invariant_claimedPlusRefundedLeDeposited() public view {
        uint256 n = tab.nextTabId();
        uint256 claimedSum;
        uint256 refundedSum;
        uint256 depositedSum;
        for (uint256 id = 1; id < n; id++) {
            CallTab.Tab memory t = tab.getTab(id);
            assertLe(t.claimed + t.refunded, t.deposited);
            claimedSum += t.claimed;
            refundedSum += t.refunded;
            depositedSum += t.deposited;
            if (t.status == CallTab.Status.Closed) {
                assertEq(t.claimed + t.refunded, t.deposited);
                assertEq(tab.remaining(id), 0);
            }
            if (handler.ghostMaxVoucher(id) > 0) {
                // paid to the provider never exceeds the highest redeemed voucher
                assertLe(t.claimed, handler.ghostMaxVoucher(id));
            }
        }
        assertEq(claimedSum, handler.ghostClaimed());
        assertEq(refundedSum, handler.ghostRefunded());
        assertEq(depositedSum, handler.ghostDeposited());
        assertEq(claimedSum + refundedSum + usdc.balanceOf(address(tab)), depositedSum);
    }
}
