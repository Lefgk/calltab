// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title Calltab
/// @notice Prepaid USDC tab between a payer (or its agent key) and a service provider.
///         The payer locks USDC, signs EIP-712 cumulative vouchers, and the provider
///         redeems only the unpaid delta. Close uses a challenge window so the provider
///         can submit a last voucher before the remainder is refunded.
/// @dev Prototype, not audited. USDC-only. No protocol fee and no admin in v1.
contract CallTab is EIP712, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // --- types ---

    enum Status {
        Open,
        Closing,
        Closed
    }

    struct Tab {
        address payer;
        address provider;
        address agent;
        uint256 deposited;
        uint256 claimed;
        uint256 refunded;
        uint256 periodCap;
        uint256 periodSpent;
        uint64 periodDuration;
        uint64 periodStart;
        uint64 expiry;
        uint64 challengeWindow;
        uint64 closeInitiatedAt;
        Status status;
        bool paused;
        uint256 payerAgentId;
        uint256 providerAgentId;
    }

    struct Voucher {
        uint256 tabId;
        uint256 cumulativeAmount;
        uint256 deadline;
    }

    // --- errors ---

    error ZeroAddress();
    error ZeroAmount();
    error SelfTab();
    error InvalidPeriod();
    error InvalidExpiry();
    error InvalidChallengeWindow();
    error UnknownTab();
    error NotPayer();
    error NotProvider();
    error NotOpen();
    error NotClosing();
    error AlreadyPaused();
    error NotPaused();
    error TabPaused();
    error WindowClosed();
    error WindowOpen();
    error NothingOwed();
    error VoucherExpired();
    error BadSignature();
    error EmptyTab();
    error ExceedsPeriodCap(uint256 requested, uint256 remainingCap);

    // --- events ---

    event TabOpened(
        uint256 indexed tabId,
        address indexed payer,
        address indexed provider,
        uint256 amount,
        uint256 periodCap,
        uint64 periodDuration,
        uint64 expiry,
        uint64 challengeWindow,
        address agent,
        uint256 payerAgentId,
        uint256 providerAgentId
    );
    event TopUp(uint256 indexed tabId, uint256 amount, uint256 deposited);
    event AgentSet(uint256 indexed tabId, address agent);
    event Paused(uint256 indexed tabId);
    event Unpaused(uint256 indexed tabId);
    event Redeemed(
        uint256 indexed tabId,
        address indexed signer,
        uint256 cumulativeAmount,
        uint256 paid,
        uint256 claimed
    );
    event CloseInitiated(uint256 indexed tabId, uint64 closeInitiatedAt, uint64 challengeWindow);
    event CloseFinalized(uint256 indexed tabId, uint256 refundedAmount, uint256 claimed);

    // --- constants / immutables ---

    bytes32 public constant VOUCHER_TYPEHASH =
        keccak256("Voucher(uint256 tabId,uint256 cumulativeAmount,uint256 deadline)");

    uint64 public constant MIN_CHALLENGE_WINDOW = 1 hours;
    uint64 public constant MAX_CHALLENGE_WINDOW = 7 days;

    IERC20 public immutable usdc;

    // --- storage ---

    uint256 public nextTabId = 1;
    mapping(uint256 => Tab) internal _tabs;
    mapping(address => uint256[]) internal _tabsOfPayer;
    mapping(address => uint256[]) internal _tabsOfProvider;

    constructor(address usdc_) EIP712("Calltab", "1") {
        if (usdc_ == address(0)) revert ZeroAddress();
        usdc = IERC20(usdc_);
    }

    // --- views ---

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @notice EIP-712 digest a payer or agent must sign for this voucher.
    function hashVoucher(uint256 tabId, uint256 cumulativeAmount, uint256 deadline)
        public
        view
        returns (bytes32)
    {
        return _hashTypedDataV4(
            keccak256(abi.encode(VOUCHER_TYPEHASH, tabId, cumulativeAmount, deadline))
        );
    }

    function getTab(uint256 tabId) external view returns (Tab memory) {
        return _tabs[tabId];
    }

    function remaining(uint256 tabId) public view returns (uint256) {
        Tab storage t = _tabs[tabId];
        return t.deposited - t.claimed - t.refunded;
    }

    function tabsOfPayer(address payer) external view returns (uint256[] memory) {
        return _tabsOfPayer[payer];
    }

    function tabsOfProvider(address provider) external view returns (uint256[] memory) {
        return _tabsOfProvider[provider];
    }

    // --- lifecycle ---

    /// @param periodCap Max redeemable in each fixed window. 0 disables the cap (periodDuration must be 0).
    /// @param expiry Unix time after which the tab is considered expired (metadata / UX). 0 = none.
    ///         Vouchers can still be redeemed until close is finalized, unless paused (open state only).
    /// @param challengeWindow Must be in [1 hour, 7 days]. Starts when the payer initiates close.
    /// @param agent Optional hot key authorized to sign vouchers. address(0) means payer only.
    /// @param payerAgentId Optional ERC-8004 id (metadata only).
    /// @param providerAgentId Optional ERC-8004 id (metadata only).
    function openTab(
        address provider,
        uint256 amount,
        uint256 periodCap,
        uint64 periodDuration,
        uint64 expiry,
        uint64 challengeWindow,
        address agent,
        uint256 payerAgentId,
        uint256 providerAgentId
    ) external nonReentrant returns (uint256 tabId) {
        if (provider == address(0)) revert ZeroAddress();
        if (provider == msg.sender) revert SelfTab();
        if (amount == 0) revert ZeroAmount();
        if ((periodCap == 0) != (periodDuration == 0)) revert InvalidPeriod();
        if (expiry != 0 && expiry <= block.timestamp) revert InvalidExpiry();
        if (challengeWindow < MIN_CHALLENGE_WINDOW || challengeWindow > MAX_CHALLENGE_WINDOW) {
            revert InvalidChallengeWindow();
        }

        tabId = nextTabId++;
        Tab storage t = _tabs[tabId];
        t.payer = msg.sender;
        t.provider = provider;
        t.agent = agent;
        t.deposited = amount;
        t.periodCap = periodCap;
        t.periodDuration = periodDuration;
        t.periodStart = uint64(block.timestamp);
        t.expiry = expiry;
        t.challengeWindow = challengeWindow;
        t.status = Status.Open;
        t.payerAgentId = payerAgentId;
        t.providerAgentId = providerAgentId;

        _tabsOfPayer[msg.sender].push(tabId);
        _tabsOfProvider[provider].push(tabId);

        usdc.safeTransferFrom(msg.sender, address(this), amount);
        emit TabOpened(
            tabId,
            msg.sender,
            provider,
            amount,
            periodCap,
            periodDuration,
            expiry,
            challengeWindow,
            agent,
            payerAgentId,
            providerAgentId
        );
    }

    function topUp(uint256 tabId, uint256 amount) external nonReentrant {
        Tab storage t = _requirePayer(tabId);
        if (t.status != Status.Open) revert NotOpen();
        if (amount == 0) revert ZeroAmount();
        t.deposited += amount;
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        emit TopUp(tabId, amount, t.deposited);
    }

    function setAgent(uint256 tabId, address agent) external {
        Tab storage t = _requirePayer(tabId);
        if (t.status != Status.Open) revert NotOpen();
        t.agent = agent;
        emit AgentSet(tabId, agent);
    }

    function pause(uint256 tabId) external {
        Tab storage t = _requirePayer(tabId);
        if (t.status != Status.Open) revert NotOpen();
        if (t.paused) revert AlreadyPaused();
        t.paused = true;
        emit Paused(tabId);
    }

    function unpause(uint256 tabId) external {
        Tab storage t = _requirePayer(tabId);
        if (t.status != Status.Open) revert NotOpen();
        if (!t.paused) revert NotPaused();
        t.paused = false;
        emit Unpaused(tabId);
    }

    /// @notice Provider redeems the latest cumulative voucher. Only the unpaid delta is paid,
    ///         and never more than the remaining deposit. Replays (same or lower cumulative)
    ///         revert. A period cap, if set, is a hard revert rather than a silent partial fill.
    function redeem(uint256 tabId, uint256 cumulativeAmount, uint256 deadline, bytes calldata signature)
        external
        nonReentrant
    {
        Tab storage t = _existing(tabId);
        if (msg.sender != t.provider) revert NotProvider();
        if (t.status == Status.Closed) revert NotOpen();
        if (t.status == Status.Open) {
            if (t.paused) revert TabPaused();
        } else {
            // Closing: last-voucher window. Pause cannot block this.
            if (block.timestamp > uint256(t.closeInitiatedAt) + uint256(t.challengeWindow)) {
                revert WindowClosed();
            }
        }
        if (cumulativeAmount <= t.claimed) revert NothingOwed();
        if (deadline != 0 && block.timestamp > deadline) revert VoucherExpired();

        bytes32 digest = hashVoucher(tabId, cumulativeAmount, deadline);
        address signer = ECDSA.recover(digest, signature);
        if (signer != t.payer && (t.agent == address(0) || signer != t.agent)) revert BadSignature();

        uint256 owed = cumulativeAmount - t.claimed;
        uint256 avail = t.deposited - t.claimed - t.refunded;
        if (avail == 0) revert EmptyTab();
        uint256 pay = owed < avail ? owed : avail;

        if (t.periodCap > 0) {
            _rollPeriod(t);
            uint256 room = t.periodCap - t.periodSpent;
            if (pay > room) revert ExceedsPeriodCap(pay, room);
            t.periodSpent += pay;
        }

        t.claimed += pay;
        usdc.safeTransfer(t.provider, pay);
        emit Redeemed(tabId, signer, cumulativeAmount, pay, t.claimed);
    }

    function initiateClose(uint256 tabId) external {
        Tab storage t = _requirePayer(tabId);
        if (t.status != Status.Open) revert NotOpen();
        t.status = Status.Closing;
        t.closeInitiatedAt = uint64(block.timestamp);
        emit CloseInitiated(tabId, t.closeInitiatedAt, t.challengeWindow);
    }

    /// @notice After the challenge window, anyone can finalize. Remainder goes back to the payer.
    function finalizeClose(uint256 tabId) external nonReentrant {
        Tab storage t = _existing(tabId);
        if (t.status != Status.Closing) revert NotClosing();
        if (block.timestamp <= uint256(t.closeInitiatedAt) + uint256(t.challengeWindow)) {
            revert WindowOpen();
        }
        t.status = Status.Closed;
        uint256 refund = t.deposited - t.claimed - t.refunded;
        if (refund > 0) {
            t.refunded += refund;
            usdc.safeTransfer(t.payer, refund);
        }
        emit CloseFinalized(tabId, refund, t.claimed);
    }

    // --- internals ---

    function _rollPeriod(Tab storage t) internal {
        uint256 duration = t.periodDuration;
        if (duration == 0) return;
        if (block.timestamp >= uint256(t.periodStart) + duration) {
            uint256 elapsed = block.timestamp - uint256(t.periodStart);
            t.periodStart += uint64((elapsed / duration) * duration);
            t.periodSpent = 0;
        }
    }

    function _existing(uint256 tabId) internal view returns (Tab storage t) {
        t = _tabs[tabId];
        if (t.payer == address(0)) revert UnknownTab();
    }

    function _requirePayer(uint256 tabId) internal view returns (Tab storage t) {
        t = _existing(tabId);
        if (msg.sender != t.payer) revert NotPayer();
    }
}
