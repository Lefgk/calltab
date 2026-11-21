# Calltab — status

Prototype on the box at `/workspace/pm-builds/calltab`. Not deployed. Not audited. No GitHub remote yet.

## Needs Lef's review

1. Audit before any mainnet or Base deploy.
2. Chain order — recommendation: Base first (cheaper gas), then Ethereum.
3. Owner wallet or Safe to be the deployer (and later the payer for a first live tab).
4. Etherscan API key for v2 verify.
5. The choices in SPEC.md: no fee, no admin, single contract, fixed period windows, min 1-hour close window, vouchers redeemable after expiry until close is finalized.
6. Name: Calltab.

## Hard limits still in force

No live broadcast, no keys or funds in this repo, no push to a production branch without Lef's OK.
