// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {CallTab} from "../../src/CallTab.sol";
import {DeployConfig} from "../../script/DeployConfig.sol";

interface IFiatToken is IERC20Metadata {
    function masterMinter() external view returns (address);
    function configureMinter(address minter, uint256 minterAllowedAmount) external returns (bool);
    function mint(address to, uint256 amount) external returns (bool);
}

/// @dev Runs against a fork of a live chain using the chain's real Circle USDC.
///      Either run `forge test --fork-url <rpc>` (only the matching chain's suite runs), or set
///      MAINNET_FORK_RPC / BASE_FORK_RPC (e.g. a local `anvil --fork-url`). Otherwise skipped.
abstract contract ForkBase is Test {
    CallTab internal tab;
    IERC20Metadata internal usdc;
    uint256 internal payerKey;
    address internal payer;
    address internal provider;
    bool internal active;

    uint64 internal constant WINDOW = 1 hours;
    uint256 internal constant DEPOSIT = 1_000e6;

    function _rpcEnv() internal pure virtual returns (string memory);
    function _chainId() internal pure virtual returns (uint256);

    function setUp() public {
        if (block.chainid == _chainId()) {
            // already running on this chain's fork (forge test --fork-url ...)
        } else if (block.chainid == 31337) {
            string memory rpc = vm.envOr(_rpcEnv(), string(""));
            if (bytes(rpc).length == 0) return;
            vm.createSelectFork(rpc);
        } else {
            return;
        }
        active = true;
        assertEq(block.chainid, _chainId(), "wrong fork chain");
        usdc = IERC20Metadata(DeployConfig.get(block.chainid).usdc);
        tab = new CallTab(address(usdc));

        payerKey = 0xA11CE;
        payer = vm.addr(payerKey);
        provider = makeAddr("fork-provider");

        _fundUsdc(payer, 10_000e6);
        vm.prank(payer);
        usdc.approve(address(tab), type(uint256).max);
    }

    function _fundUsdc(address to, uint256 amount) internal {
        IFiatToken token = IFiatToken(address(usdc));
        address master = token.masterMinter();
        vm.prank(master);
        token.configureMinter(address(this), type(uint256).max);
        bool minted = token.mint(to, amount);
        require(minted || token.balanceOf(to) >= amount, "fork: USDC mint failed");
    }

    modifier onFork() {
        if (!active) {
            vm.skip(true);
            return;
        }
        _;
    }

    function _sign(uint256 tabId, uint256 cumulative, uint256 deadline) internal view returns (bytes memory) {
        bytes32 digest = tab.hashVoucher(tabId, cumulative, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(payerKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function test_fork_realUsdcMetadata() public onFork {
        assertEq(usdc.symbol(), "USDC");
        assertEq(usdc.decimals(), 6);
        assertGt(address(usdc).code.length, 0);
        assertEq(address(usdc), DeployConfig.get(block.chainid).usdc);
    }

    function test_fork_openRedeemCloseWithRealUsdc() public onFork {
        vm.prank(payer);
        uint256 id = tab.openTab(provider, DEPOSIT, 100e6, 1 days, 0, WINDOW, address(0), 7, 8);
        assertEq(usdc.balanceOf(address(tab)), DEPOSIT);

        bytes memory firstSig = _sign(id, 40e6, 0);
        vm.prank(provider);
        tab.redeem(id, 40e6, 0, firstSig);
        assertEq(usdc.balanceOf(provider), 40e6);
        assertEq(tab.remaining(id), 960e6);

        // period cap
        bytes memory capSig = _sign(id, 120e6, 0);
        vm.prank(provider);
        vm.expectRevert(abi.encodeWithSelector(CallTab.ExceedsPeriodCap.selector, 80e6, 60e6));
        tab.redeem(id, 120e6, 0, capSig);

        vm.prank(payer);
        tab.initiateClose(id);
        bytes memory closeSig = _sign(id, 70e6, 0);
        vm.prank(provider);
        tab.redeem(id, 70e6, 0, closeSig);
        assertEq(usdc.balanceOf(provider), 70e6);

        vm.warp(block.timestamp + WINDOW + 1);
        uint256 before = usdc.balanceOf(payer);
        tab.finalizeClose(id);
        assertEq(usdc.balanceOf(payer), before + (DEPOSIT - 70e6));
        assertEq(usdc.balanceOf(address(tab)), 0);
        assertEq(tab.remaining(id), 0);
    }

    function test_fork_crossTabReplayRejected() public onFork {
        vm.startPrank(payer);
        uint256 a = tab.openTab(provider, 100e6, 0, 0, 0, WINDOW, address(0), 0, 0);
        uint256 b = tab.openTab(provider, 100e6, 0, 0, 0, WINDOW, address(0), 0, 0);
        vm.stopPrank();
        bytes memory sigA = _sign(a, 50e6, 0);
        vm.prank(provider);
        vm.expectRevert(CallTab.BadSignature.selector);
        tab.redeem(b, 50e6, 0, sigA);
        vm.prank(provider);
        tab.redeem(a, 50e6, 0, sigA);
        assertEq(tab.getTab(a).claimed, 50e6);
        assertEq(tab.getTab(b).claimed, 0);
    }
}

contract EthereumForkTest is ForkBase {
    function _rpcEnv() internal pure override returns (string memory) {
        return "MAINNET_FORK_RPC";
    }

    function _chainId() internal pure override returns (uint256) {
        return 1;
    }
}

contract BaseForkTest is ForkBase {
    function _rpcEnv() internal pure override returns (string memory) {
        return "BASE_FORK_RPC";
    }

    function _chainId() internal pure override returns (uint256) {
        return 8453;
    }
}
