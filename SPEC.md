# Calltab — spec (prototype, 22 Nov 2026)

Source: payments research, idea 2. Complements Agent Spend Controls: the owner still caps spend, while a provider gets a locked tab they can debit with signed vouchers.

**Problem.** x402 is a per-call exact transfer, awkward for sub-cent calls, with no tab or refund if a call fails. Hosted sessions (Nevermined, Skyfire) are closed or the wrong chain. Streams (Sablier, Superfluid) charge by time, not by call.

**Users.** Builders running paying agents, and provider agents that want to settle later, not per request.

**Scope (v0, Ethereum mainnet and Base, after an audit and Lef's OK).**
- One `CallTab` contract per chain, many tabs by id. USDC only. No admin and no protocol fee.
- Payer locks USDC with a provider, an optional fixed-window period cap, optional expiry, and a challenge window (1 hour–7 days). Optional ERC-8004 ids are metadata only.
- Payer or one agent key signs EIP-712 cumulative vouchers. The provider redeems only the unpaid delta, never more than the deposit. Domain binds chain and contract; the voucher binds `tabId` — no replay across tabs or chains.
- Payer can pause (blocks redeem while open), top up, and rotate the agent. Close starts a challenge window so the provider can submit a last voucher even if paused; then anyone can finalize and the remainder is refunded.
- Simple dapp: open, sign, redeem, pause, close. TypeScript helper to sign and verify vouchers.

**Out.** Other chains, ETH, fees, a clone factory, automatic close at expiry.

**Choices for Lef to review.** No fee and no owner; single contract, not a factory; fixed period windows; no withdraw except through close; min 1-hour challenge window; vouchers redeemable after expiry until close is finalized; Base first for a cheaper first deploy.
