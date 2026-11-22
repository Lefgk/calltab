# Calltab

Prepaid USDC tabs between a payer (an agent or its owner) and a service provider. The payer locks USDC, signs **EIP-712 cumulative vouchers**, and the provider **redeems only the unpaid delta**. The payer can **pause**, and can **close with a challenge window** so the provider can submit a last voucher before the remainder is refunded.

> Prototype, **not audited**. It targets **Ethereum mainnet (1)** and **Base (8453)**, plus local anvil (31337) for development. The deploy scripts refuse any other chain and **refuse to broadcast on 1/8453 unless `CONFIRM_MAINNET=yes`**. Nothing has been deployed.

See [SPEC.md](SPEC.md) for the problem, competitors and choices, [DEPLOY.md](DEPLOY.md) for the deploy runbook, and [STATUS.md](STATUS.md) for what still needs Lef's decision.

## Layout
| Path | What |
|---|---|
| `src/CallTab.sol` | Tabs, EIP-712 vouchers, pause, close + challenge window |
| `src/MockUSDC.sol` | 6-decimal test token, used locally only |
| `test/` | Unit, fuzz and invariant tests (Foundry) |
| `test/fork/` | Fork tests against real Circle USDC, plus a fork test of `Deploy.s.sol` |
| `script/Deploy.s.sol`, `script/DeployConfig.sol` | Deploy script and per-chain config (USDC addresses, live-chain flag) |
| `script/deploy.sh`, `script/verify.sh`, `script/deploy-anvil.sh` | Dry-run/broadcast wrapper, Etherscan v2 verify, local deploy |
| `script/dry-run-fork.sh`, `script/write-web-config.sh` | Anvil-fork dry run (port 8627) and dapp-config writer |
| `web/` | Simple Vite + React + wagmi/viem tab page |
| `web/src/lib/voucher.ts` | TypeScript helper to sign and verify vouchers (vitest in `web`) |
| `sdk/` | Re-exports the voucher helper for agents |

## Quick start

```bash
# unit, fuzz and invariant tests
forge test

# production dapp build (also runs TypeScript check)
cd web && npm ci && npm run build && npm test

# deploy-script dry run + guard check on a local mainnet/Base fork (port 8627)
make dry-run-mainnet
make test-fork-deploy
```

Local dapp:

```bash
anvil --port 8627                 # terminal 1, chain 31337
./script/deploy-anvil.sh          # uses anvil's unlocked dev account #0
cd web && npm install && npm run dev  # http://localhost:5173
```

Live deploy needs Lef's wallet and `CONFIRM_MAINNET=yes`. See [DEPLOY.md](DEPLOY.md). Never commit `.env` or keys.

## Contact

Support and questions: [lg.playstudio@gmail.com](mailto:lg.playstudio@gmail.com)
