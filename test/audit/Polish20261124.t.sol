// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {CallTab} from "../../src/CallTab.sol";
import {MockUSDC} from "../../src/MockUSDC.sol";

/// @dev 6-decimals token whose transfer/transferFrom call back into a target (ERC-777 style hook).
contract HookToken is ERC20 {
    address public target;
    bytes public payload;
    bool public reentered;
    bool public reentrySucceeded;

    constructor() ERC20("Hook", "HK") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }

    function arm(address t, bytes calldata p) external {
        target = t;
        payload = p;
        reentered = false;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (target != address(0) && !reentered) {
            reentered = true;
            (bool ok,) = target.call(payload);
            reentrySucceeded = ok;
        }
    }
}

/// @dev USDT-style: transfer/transferFrom/approve return nothing.
contract NoReturnToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address s, uint256 a) external {
        allowance[msg.sender][s] = a;
    }

    function transfer(address to, uint256 a) external {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
    }

    function transferFrom(address f, address to, uint256 a) external {
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[to] += a;
    }
}

contract Polish20261124Test is Test {
    CallTab internal tab;
    MockUSDC internal usdc;

    uint256 internal constant PAYER_KEY = 0xA11CE;
    uint256 internal constant AGENT_KEY = 0xA6E17;
    address internal payer;
    address internal agent;
    address internal provider;
    address internal stranger;

    uint64 internal constant WINDOW = 1 hours;
    uint256 internal constant DEPOSIT = 1_000e6;

    function setUp() public {
        usdc = new MockUSDC();
        tab = new CallTab(address(usdc));
        payer = vm.addr(PAYER_KEY);
        agent = vm.addr(AGENT_KEY);
        provider = makeAddr("provider");
        stranger = makeAddr("stranger");
        usdc.mint(payer, 1_000_000e6);
        vm.prank(payer);
        usdc.approve(address(tab), type(uint256).max);
    }

    function _open(uint256 cap, uint64 dur, address ag) internal returns (uint256 id) {
        vm.prank(payer);
        id = tab.openTab(provider, DEPOSIT, cap, dur, 0, WINDOW, ag, 0, 0);
    }

    function _sig(uint256 key, uint256 id, uint256 cum, uint256 dl) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, tab.hashVoucher(id, cum, dl));
        return abi.encodePacked(r, s, v);
    }

    function _redeem(uint256 id, uint256 cum) internal {
        bytes memory s = _sig(PAYER_KEY, id, cum, 0);
        vm.prank(provider);
        tab.redeem(id, cum, 0, s);
    }

    // --- access control / state machine ---

    function test_finalizeCloseGuards() public {
        uint256 id = _open(0, 0, address(0));
        vm.expectRevert(CallTab.NotClosing.selector);
        tab.finalizeClose(id);
        vm.expectRevert(CallTab.UnknownTab.selector);
        tab.finalizeClose(999);

        vm.prank(payer);
        tab.initiateClose(id);
        vm.warp(block.timestamp + WINDOW); // boundary: still open (<=)
        vm.expectRevert(CallTab.WindowOpen.selector);
        tab.finalizeClose(id);

        vm.warp(block.timestamp + 1);
        vm.prank(stranger); // permissionless
        tab.finalizeClose(id);
        assertEq(usdc.balanceOf(payer), 1_000_000e6);

        vm.expectRevert(CallTab.NotClosing.selector); // no double finalize
        tab.finalizeClose(id);
        vm.prank(payer);
        vm.expectRevert(CallTab.NotOpen.selector);
        tab.initiateClose(id);
    }

    function test_finalizeCloseWithFullyClaimedRefundsNothing() public {
        uint256 id = _open(0, 0, address(0));
        _redeem(id, DEPOSIT);
        vm.prank(payer);
        tab.initiateClose(id);
        vm.warp(block.timestamp + WINDOW + 1);
        uint256 before = usdc.balanceOf(payer);
        tab.finalizeClose(id);
        assertEq(usdc.balanceOf(payer), before);
        assertEq(tab.remaining(id), 0);
        assertEq(usdc.balanceOf(address(tab)), 0);
    }

    function test_redeemAfterClosedOrWindowElapsedReverts() public {
        uint256 id = _open(0, 0, address(0));
        vm.prank(payer);
        tab.initiateClose(id);
        bytes memory s = _sig(PAYER_KEY, id, 100e6, 0);

        vm.warp(block.timestamp + WINDOW); // last second of window still works
        vm.prank(provider);
        tab.redeem(id, 100e6, 0, s);

        bytes memory s2 = _sig(PAYER_KEY, id, 200e6, 0);
        vm.warp(block.timestamp + 1);
        vm.prank(provider);
        vm.expectRevert(CallTab.WindowClosed.selector);
        tab.redeem(id, 200e6, 0, s2);

        tab.finalizeClose(id);
        vm.prank(provider);
        vm.expectRevert(CallTab.NotOpen.selector);
        tab.redeem(id, 200e6, 0, s2);
    }

    function test_redeemUnknownTabAndEmptyTab() public {
        vm.prank(provider);
        vm.expectRevert(CallTab.UnknownTab.selector);
        tab.redeem(42, 1, 0, "");

        uint256 id = _open(0, 0, address(0));
        _redeem(id, DEPOSIT);
        bytes memory s = _sig(PAYER_KEY, id, DEPOSIT + 5, 0);
        vm.prank(provider);
        vm.expectRevert(CallTab.EmptyTab.selector);
        tab.redeem(id, DEPOSIT + 5, 0, s);
    }

    function test_redeemGarbageSignatureReverts() public {
        uint256 id = _open(0, 0, address(0));
        vm.prank(provider);
        vm.expectRevert(); // ECDSAInvalidSignatureLength
        tab.redeem(id, 1, 0, hex"1234");
        vm.prank(provider);
        vm.expectRevert(); // ECDSAInvalidSignature (zero sig -> address(0))
        tab.redeem(id, 1, 0, new bytes(65));
    }

    function test_voucherDeadlineBoundaryAndTamperedFields() public {
        uint256 id = _open(0, 0, address(0));
        uint256 dl = block.timestamp + 100;
        bytes memory s = _sig(PAYER_KEY, id, 10e6, dl);

        // tampered amount / deadline do not verify
        vm.prank(provider);
        vm.expectRevert(CallTab.BadSignature.selector);
        tab.redeem(id, 11e6, dl, s);
        vm.prank(provider);
        vm.expectRevert(CallTab.BadSignature.selector);
        tab.redeem(id, 10e6, dl + 1, s);

        vm.warp(dl); // exactly at deadline is valid
        vm.prank(provider);
        tab.redeem(id, 10e6, dl, s);

        bytes memory s2 = _sig(PAYER_KEY, id, 20e6, dl);
        vm.warp(dl + 1);
        vm.prank(provider);
        vm.expectRevert(CallTab.VoucherExpired.selector);
        tab.redeem(id, 20e6, dl, s2);
    }

    function test_pauseBoundaryAndSetAgentWhilePaused() public {
        uint256 id = _open(0, 0, agent);
        vm.prank(payer);
        tab.pause(id);
        uint256 t0 = block.timestamp;

        vm.warp(t0 + WINDOW); // boundary: > not >=, still redeemable
        bytes memory s = _sig(AGENT_KEY, id, 10e6, 0);
        vm.prank(provider);
        tab.redeem(id, 10e6, 0, s);

        vm.warp(t0 + WINDOW + 1);
        bytes memory s2 = _sig(AGENT_KEY, id, 20e6, 0);
        vm.prank(provider);
        vm.expectRevert(CallTab.TabPaused.selector);
        tab.redeem(id, 20e6, 0, s2);

        // payer can still start close, and provider then redeems in the closing window
        vm.prank(payer);
        tab.initiateClose(id);
        vm.prank(provider);
        tab.redeem(id, 20e6, 0, s2);
        assertEq(tab.getTab(id).claimed, 20e6);

        // closed/closing: pause, unpause, setAgent all NotOpen
        vm.startPrank(payer);
        vm.expectRevert(CallTab.NotOpen.selector);
        tab.setAgent(id, address(0));
        vm.expectRevert(CallTab.NotOpen.selector);
        tab.unpause(id);
        vm.stopPrank();
    }

    function test_pauseUnpauseAccessAndEvents() public {
        uint256 id = _open(0, 0, address(0));
        vm.prank(stranger);
        vm.expectRevert(CallTab.NotPayer.selector);
        tab.pause(id);
        vm.prank(payer);
        vm.expectRevert(CallTab.NotPaused.selector);
        tab.unpause(id);
        vm.prank(payer);
        vm.expectEmit(true, false, false, false);
        emit CallTab.Paused(id);
        tab.pause(id);
        assertEq(tab.pausedAt(id), block.timestamp);
        vm.prank(payer);
        vm.expectEmit(true, false, false, false);
        emit CallTab.Unpaused(id);
        tab.unpause(id);
        assertEq(tab.pausedAt(id), 0);
    }

    function test_agentCannotAdministerTab() public {
        uint256 id = _open(0, 0, agent);
        vm.startPrank(agent);
        vm.expectRevert(CallTab.NotPayer.selector);
        tab.pause(id);
        vm.expectRevert(CallTab.NotPayer.selector);
        tab.initiateClose(id);
        vm.expectRevert(CallTab.NotPayer.selector);
        tab.setAgent(id, agent);
        vm.expectRevert(CallTab.NotPayer.selector);
        tab.topUp(id, 1);
        vm.stopPrank();
    }

    function test_agentCannotRedeemItself() public {
        uint256 id = _open(0, 0, agent);
        bytes memory s = _sig(AGENT_KEY, id, 1e6, 0);
        vm.prank(agent);
        vm.expectRevert(CallTab.NotProvider.selector);
        tab.redeem(id, 1e6, 0, s);
    }

    function test_setAgentSameAgentNoGraceAndFromZeroNoGrace() public {
        uint256 id = _open(0, 0, agent);
        vm.prank(payer);
        tab.setAgent(id, agent);
        assertEq(tab.previousAgent(id), address(0));

        uint256 id2 = _open(0, 0, address(0));
        vm.prank(payer);
        tab.setAgent(id2, agent);
        assertEq(tab.previousAgent(id2), address(0));
        assertEq(tab.previousAgentUntil(id2), 0);
    }

    function test_graceBoundaryAndNewRotationAfterGrace() public {
        uint256 id = _open(0, 0, agent);
        address agent2 = vm.addr(0xA6E18);
        vm.prank(payer);
        tab.setAgent(id, agent2);
        uint256 t0 = block.timestamp;

        vm.warp(t0 + WINDOW); // last valid second of grace
        bytes memory s = _sig(AGENT_KEY, id, 5e6, 0);
        vm.prank(provider);
        tab.redeem(id, 5e6, 0, s);

        vm.warp(t0 + WINDOW + 1);
        bytes memory s2 = _sig(AGENT_KEY, id, 6e6, 0);
        vm.prank(provider);
        vm.expectRevert(CallTab.BadSignature.selector);
        tab.redeem(id, 6e6, 0, s2);

        vm.prank(payer);
        tab.setAgent(id, agent); // rotation allowed once grace ended
        assertEq(tab.previousAgent(id), agent2);
    }

    // --- period cap ---

    function test_periodCapSkipsMultiplePeriodsAndAlignsStart() public {
        uint256 t0 = block.timestamp;
        uint256 id = _open(100e6, 1 days, address(0));
        _redeem(id, 100e6);
        vm.warp(t0 + 3 days + 5 hours);
        _redeem(id, 200e6);
        assertEq(tab.getTab(id).periodSpent, 100e6);
        assertEq(tab.getTab(id).periodStart, t0 + 3 days);
        // exact boundary of next period rolls
        vm.warp(t0 + 4 days);
        _redeem(id, 300e6);
        assertEq(tab.getTab(id).periodStart, t0 + 4 days);
    }

    function test_periodCapExactBoundaryNotYetRolled() public {
        uint256 t0 = block.timestamp;
        uint256 id = _open(100e6, 1 days, address(0));
        _redeem(id, 100e6);
        vm.warp(t0 + 1 days - 1);
        bytes memory s = _sig(PAYER_KEY, id, 101e6, 0);
        vm.prank(provider);
        vm.expectRevert(abi.encodeWithSelector(CallTab.ExceedsPeriodCap.selector, 1e6, 0));
        tab.redeem(id, 101e6, 0, s);
    }

    function test_periodCapAppliesToAgentGraceVoucher() public {
        uint256 id = _open(10e6, 1 days, agent);
        vm.prank(payer);
        tab.setAgent(id, address(0));
        bytes memory s = _sig(AGENT_KEY, id, 50e6, 0);
        vm.prank(provider);
        vm.expectRevert(abi.encodeWithSelector(CallTab.ExceedsPeriodCap.selector, 50e6, 10e6));
        tab.redeem(id, 50e6, 0, s);
    }

    // --- open / topUp / views ---

    function test_openTabGuardsAndIndexing() public {
        vm.startPrank(payer);
        vm.expectRevert(CallTab.ZeroAddress.selector);
        tab.openTab(address(0), 1, 0, 0, 0, WINDOW, address(0), 0, 0);
        vm.expectRevert(CallTab.SelfTab.selector);
        tab.openTab(payer, 1, 0, 0, 0, WINDOW, address(0), 0, 0);
        vm.expectRevert(CallTab.ZeroAmount.selector);
        tab.openTab(provider, 0, 0, 0, 0, WINDOW, address(0), 0, 0);
        vm.expectRevert(CallTab.InvalidPeriod.selector);
        tab.openTab(provider, 1, 5, 0, 0, WINDOW, address(0), 0, 0);
        vm.expectRevert(CallTab.InvalidPeriod.selector);
        tab.openTab(provider, 1, 0, 5, 0, WINDOW, address(0), 0, 0);
        vm.expectRevert(CallTab.InvalidExpiry.selector);
        tab.openTab(provider, 1, 0, 0, uint64(block.timestamp), WINDOW, address(0), 0, 0);
        vm.expectRevert(CallTab.InvalidChallengeWindow.selector);
        tab.openTab(provider, 1, 0, 0, 0, 7 days + 1, address(0), 0, 0);
        vm.stopPrank();

        uint256 a = _open(0, 0, address(0));
        uint256 b = _open(0, 0, address(0));
        assertEq(a, 1);
        assertEq(b, 2);
        assertEq(tab.tabsOfPayer(payer).length, 2);
        assertEq(tab.tabsOfProvider(provider)[1], 2);
    }

    function test_openTabWithoutAllowanceOrBalanceReverts() public {
        vm.prank(stranger);
        vm.expectRevert();
        tab.openTab(provider, 1e6, 0, 0, 0, WINDOW, address(0), 0, 0);
        assertEq(tab.nextTabId(), 1);
    }

    function test_topUpZeroAndUnknown() public {
        uint256 id = _open(0, 0, address(0));
        vm.startPrank(payer);
        vm.expectRevert(CallTab.ZeroAmount.selector);
        tab.topUp(id, 0);
        vm.expectRevert(CallTab.UnknownTab.selector);
        tab.topUp(77, 1);
        vm.stopPrank();
    }

    function test_topUpWhilePausedAndAfterPartialClaim() public {
        uint256 id = _open(0, 0, address(0));
        _redeem(id, 400e6);
        vm.startPrank(payer);
        tab.pause(id);
        tab.topUp(id, 50e6);
        vm.stopPrank();
        assertEq(tab.remaining(id), DEPOSIT - 400e6 + 50e6);
    }

    // --- reentrancy / non-standard tokens ---

    function _hookSetup(HookToken tok) internal returns (CallTab t) {
        t = new CallTab(address(tok));
        tok.mint(payer, 10_000e6);
        vm.prank(payer);
        tok.approve(address(t), type(uint256).max);
    }

    function test_reentrancyOnOpenTabBlocked() public {
        HookToken tok = new HookToken();
        CallTab t = _hookSetup(tok);
        tok.arm(address(t), abi.encodeCall(CallTab.openTab, (provider, 1, 0, 0, 0, WINDOW, address(0), 0, 0)));
        vm.prank(payer);
        t.openTab(provider, 100e6, 0, 0, 0, WINDOW, address(0), 0, 0);
        assertTrue(tok.reentered());
        assertFalse(tok.reentrySucceeded());
        assertEq(t.nextTabId(), 2);
    }

    function test_reentrancyOnRedeemAndFinalizeBlocked() public {
        HookToken tok = new HookToken();
        CallTab t = _hookSetup(tok);
        vm.prank(payer);
        uint256 id = t.openTab(provider, 100e6, 0, 0, 0, WINDOW, address(0), 0, 0);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PAYER_KEY, t.hashVoucher(id, 60e6, 0));
        bytes memory sig = abi.encodePacked(r, s, v);
        // token hook (called during provider payout) tries to redeem again as the token itself
        tok.arm(address(t), abi.encodeCall(CallTab.redeem, (id, 100e6, 0, sig)));
        vm.prank(provider);
        t.redeem(id, 60e6, 0, sig);
        assertTrue(tok.reentered());
        assertFalse(tok.reentrySucceeded());
        assertEq(t.getTab(id).claimed, 60e6);

        vm.prank(payer);
        t.initiateClose(id);
        vm.warp(block.timestamp + WINDOW + 1);
        tok.arm(address(t), abi.encodeCall(CallTab.finalizeClose, (id)));
        t.finalizeClose(id);
        assertTrue(tok.reentered());
        assertFalse(tok.reentrySucceeded());
        assertEq(tok.balanceOf(address(t)), 0);
    }

    function test_noReturnTokenWorksViaSafeERC20() public {
        NoReturnToken tok = new NoReturnToken();
        CallTab t = new CallTab(address(tok));
        tok.mint(payer, 1_000e6);
        vm.prank(payer);
        tok.approve(address(t), type(uint256).max);
        vm.prank(payer);
        uint256 id = t.openTab(provider, 500e6, 0, 0, 0, WINDOW, address(0), 0, 0);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PAYER_KEY, t.hashVoucher(id, 200e6, 0));
        vm.prank(provider);
        t.redeem(id, 200e6, 0, abi.encodePacked(r, s, v));
        vm.prank(payer);
        t.initiateClose(id);
        vm.warp(block.timestamp + WINDOW + 1);
        t.finalizeClose(id);
        assertEq(tok.balanceOf(provider), 200e6);
        assertEq(tok.balanceOf(payer), 800e6);
        assertEq(tok.balanceOf(address(t)), 0);
    }

    // --- fuzz ---

    function testFuzz_closeConservesFunds(uint96 dep, uint96 topup, uint96 cum) public {
        dep = uint96(bound(dep, 1, 100_000e6));
        topup = uint96(bound(topup, 0, 100_000e6));
        vm.prank(payer);
        uint256 id = tab.openTab(provider, dep, 0, 0, 0, WINDOW, address(0), 0, 0);
        if (topup > 0) {
            vm.prank(payer);
            tab.topUp(id, topup);
        }
        uint256 total = uint256(dep) + topup;
        cum = uint96(bound(cum, 1, type(uint96).max));
        _redeem(id, cum);
        vm.prank(payer);
        tab.initiateClose(id);
        vm.warp(block.timestamp + WINDOW + 1);
        tab.finalizeClose(id);
        uint256 paid = cum < total ? cum : total;
        assertEq(usdc.balanceOf(provider), paid);
        assertEq(usdc.balanceOf(address(tab)), 0);
        assertEq(usdc.balanceOf(payer), 1_000_000e6 - paid);
    }

    function testFuzz_periodCapNeverExceededPerWindow(uint96 cap, uint96 a, uint96 b) public {
        cap = uint96(bound(cap, 1e6, DEPOSIT));
        uint256 id = _open(cap, 1 days, address(0));
        a = uint96(bound(a, 1, DEPOSIT));
        bytes memory s1 = _sig(PAYER_KEY, id, a, 0);
        vm.prank(provider);
        if (a > cap) {
            vm.expectRevert(abi.encodeWithSelector(CallTab.ExceedsPeriodCap.selector, uint256(a), uint256(cap)));
            tab.redeem(id, a, 0, s1);
            return;
        }
        tab.redeem(id, a, 0, s1);
        b = uint96(bound(b, uint256(a) + 1, DEPOSIT + 1e6));
        uint256 want = b > DEPOSIT ? DEPOSIT : b;
        if (want <= a) return;
        bytes memory s2 = _sig(PAYER_KEY, id, b, 0);
        vm.prank(provider);
        if (want - a > cap - a) {
            vm.expectRevert(abi.encodeWithSelector(CallTab.ExceedsPeriodCap.selector, want - a, uint256(cap) - a));
        }
        tab.redeem(id, b, 0, s2);
        assertLe(tab.getTab(id).periodSpent, cap);
    }

    function testFuzz_nonProviderNeverRedeems(address caller) public {
        vm.assume(caller != provider);
        uint256 id = _open(0, 0, address(0));
        bytes memory s = _sig(PAYER_KEY, id, 1e6, 0);
        vm.prank(caller);
        vm.expectRevert(CallTab.NotProvider.selector);
        tab.redeem(id, 1e6, 0, s);
    }
}
