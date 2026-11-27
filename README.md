# Sentinel — AI Risk Guardian

**Reactive Omni Buildathon — Track 3: Reactive Meets AI**

Sentinel is an AI risk guardian for DeFi funds. An off-chain AI agent watches
the ETH/USD market, asks an LLM for a risk score (0–100), and publishes it
on-chain. A reactive contract on the Reactive Network watches the score and,
when risk crosses a threshold, automatically moves guarded funds to a safe
address — with no human in the loop and no manual transaction.

## How it works

```
                        ┌─────────────────────┐
  CoinGecko ETH/USD ──▶ │  AI agent (Node.js) │  LLM risk score 0-100
                        │  Groq free tier     │  (+ one-line reason)
                        └────────┬────────────┘
                                 │ updateScore() — real tx
                                 ▼
              ┌──────────────────────────────────┐
              │  RiskOracle — Base Sepolia       │  emits RiskScoreUpdated
              │  0xdc4e2FD88491C69058509fFb5638EF2D266f0C7e
              └──────────────┬───────────────────┘
                             │ event subscription (Reactive)
                             ▼
              ┌──────────────────────────────────┐
              │  SentinelReactive — Lasna        │  edge-triggered:
              │  0x56059b33912670C050c88393085836A43ef738AC
              │  fires once per below→above-80 crossing
              └──────────────┬───────────────────┘
                             │ callback (Reactive relayer)
                             ▼
              ┌──────────────────────────────────┐
              │  Vault — Base Sepolia            │  emergencyWithdraw()
              │  0x04c66C1dEBBa7913833dF445f3dB290bfDC77032
              │  funds → safe address, keeps a 0.005 ETH
              │  callback reserve behind
              └──────────────────────────────────┘
```

The Reactive Network is the execution layer in the critical path: the
reactive contract subscribes to the oracle's `RiskScoreUpdated` events and
its callback is what moves the funds. Without Reactive, nothing moves.

- **RiskOracle** (`src/RiskOracle.sol`) — agent-only `updateScore(score,
  reason)`; emits `RiskScoreUpdated` (score non-indexed so it lands in the
  reactive contract's `LogRecord.data`).
- **SentinelReactive** (`src/SentinelReactive.sol`) — Lasna
  `AbstractReactive`; subscribes to `RiskScoreUpdated` on Base Sepolia;
  edge-triggered (fires once per below→above-80 crossing, so a stuck-high
  score doesn't burn REACT/callback fees); owner-settable threshold/vault.
- **Vault** (`src/Vault.sol`) — Base Sepolia `AbstractCallback`;
  `emergencyWithdraw` enforces BOTH docs-mandated guards
  (`onlyServiceProvider` + `onlyCallbackSender`); keeps a 0.005 ETH callback
  reserve so the fee settles and the Vault never goes into debt.
- **AI agent** (`agent/`) — Node.js + ethers v6; CoinGecko price feed; LLM
  via OpenAI-compatible chat completions (env-configured, Groq free tier by
  default, model `qwen/qwen3.8-27b`); a built-in mock provider runs when no
  API key is set.

## Live demo (real testnet transactions)

Deployed and proven end-to-end on testnet, 27 Nov 2026 (real-LLM run):

1. Vault re-funded with 0.05 Base Sepolia ETH —
   `0xfbc42854ca8a418f82ce7ae6ce9a77d24c68a5f905a46f0497829068f04bdcd7`
   (block 64364253).
2. Agent (real LLM, Groq `qwen/qwen3.8-27b`) scored the live market:
   ETH/USD $1,671.05 (−1.03% / 24h) → **score 15** ("within normal market
   noise") — `updateScore(15)` tx
   `0xff451cc75154ff0cd26905e5d0c7741895c9a3514de15492c35eb2c515cc31e6`
   (block 64364373).
3. Forced crash score 85 published — `updateScore(85)` tx
   `0xe026492d8e62ffe39ba27f7c44552278aece79a283a42ac32922ffd827121400`
   (block 64364408).
4. Reactive processed the crossing on Lasna — `Triggered(85)` at block
   9387544, tx
   `0xebc37ae4722fd48b0366a98f1f9dd96621efa37530ede7c7caef693b8bc7d1cf`.
   The callback executed on Base Sepolia block 64364413 (just 5 blocks
   after the score-85 tx), tx
   `0x4ee90737dcefc95952c1416bf9543545378d6eb77d680c9cf1a2ba231aaa23cf`:
   Vault `EmergencyWithdrawn` **0.049999342145 ETH** to the safe address.
5. Final state (verified on-chain): Vault **0.004999342145 ETH** (0.005
   reserve minus the 0.000000657855 callback fee); safe address
   0.294988640208339141 ETH; reactive `triggerCount` 2, `lastScore` 85.

Earlier mock-provider demo (same pipeline): score 20 → 85, reactive
triggered at Lasna block 9385442, callback executed on Base Sepolia block
64353021, Vault `EmergencyWithdrawn` 0.045 ETH to the safe address.

## Setup

Requirements: [Foundry](https://getfoundry.sh) (`forge` 1.7+, solc 0.8.29),
Node.js 20+.

```bash
git clone <this repo>
cd sentinel
forge install foundry-rs/forge-std
forge install Reactive-Network/reactive-lib-omni
forge build
forge test   # 20/20 tests green
```

## Deploy (testnet only)

Order matters: oracle → reactive → vault → wire the vault in.

```bash
# 1. RiskOracle on Base Sepolia (deployer becomes the agent)
PRIVATE_KEY=<deployer-key> forge script script/DeployOracle.s.sol \
  --rpc-url https://base-sepolia-rpc.publicnode.com --broadcast

# 2. SentinelReactive on Lasna (funded 0.05 lREACT at deploy — see note below)
ORACLE_ADDRESS=<oracle> PRIVATE_KEY=<deployer-key> \
  forge script script/DeployReactive.s.sol \
  --rpc-url https://lasna-rpc.rnk.dev/ --broadcast

# 3. Vault on Base Sepolia
REACTIVE_ADDRESS=<reactive> SAFE_ADDRESS=<safe> PRIVATE_KEY=<deployer-key> \
  forge script script/DeployVault.s.sol \
  --rpc-url https://base-sepolia-rpc.publicnode.com --broadcast

# 4. Point the reactive contract at the Vault (Lasna)
REACTIVE_ADDRESS=<reactive> VAULT_ADDRESS=<vault> PRIVATE_KEY=<deployer-key> \
  forge script script/SetVault.s.sol \
  --rpc-url https://lasna-rpc.rnk.dev/ --broadcast

# 5. Fund the Vault (it guards these funds) + get lREACT for Lasna:
#    send 0.1 Base Sepolia ETH to the Reactive faucet
#    0x2afaFD298b23b62760711756088F75B7409f5967 (1 ETH -> 100 lREACT)
#    then top up the reactive contract if needed.
```

Notes:

- Use `https://base-sepolia-rpc.publicnode.com` for Base Sepolia
  (`https://sepolia.base.org` times out in some environments).
- Reactive contracts must stay **funded**: a contract in debt receives no
  further events until the debt is covered (`coverDebt()`). Our first demo
  ran with 0.02 lREACT and accrued 0.0228813 lREACT of debt, which halted
  delivery — deploy funding is now 0.05 lREACT, and each `react()` costs
  ~0.006 lREACT. Events missed while in debt are **not** replayed.
- Event delivery from Base Sepolia to Lasna takes minutes; allow for it
  (edit cuts in a demo video, not fake speed).

## Run the agent

```bash
cd agent
npm install
cp .env.example .env   # add SENTINEL_LLM_API_KEY for the real LLM;
                       # without a key the mock provider is used
node agent.mjs --once  # single cycle (real LLM scores the live market)
node agent.mjs         # loop every POLL_INTERVAL_MS (default 5 min)
node agent.mjs --demo  # end-to-end demo: publish 30, then 85, watch the Vault
node agent.mjs --score 85  # publish a forced score once (demo/debug)
```

`.env` (never commit a real key):

- `SENTINEL_LLM_API_KEY` — Groq free-tier key; unset = mock provider.
- `SENTINEL_LLM_BASE_URL` — default `https://api.groq.com/openai/v1`.
- `SENTINEL_LLM_MODEL` — default `qwen/qwen3.8-27b`.
- `RPC_URL`, `ORACLE_ADDRESS`, `WALLET_KEY_PATH`, `POLL_INTERVAL_MS`.

## Deployed contracts (testnet)

| Contract | Chain | Address |
|---|---|---|
| RiskOracle | Base Sepolia (84532) | `0xdc4e2FD88491C69058509fFb5638EF2D266f0C7e` |
| SentinelReactive | Reactive Lasna (5318007) | `0x56059b33912670C050c88393085836A43ef738AC` |
| Vault | Base Sepolia (84532) | `0x04c66C1dEBBa7913833dF445f3dB290bfDC77032` |

Verify on [Reactscan](https://reactscan.net) (Lasna) and BaseScan Sepolia.
All three contracts are Sourcify-verified (`exact_match`).

## Tests

```bash
forge test
```

20 tests: oracle auth/range, vault deposit/withdraw, emergency-withdraw
happy path + both auth reverts + empty balance, `react()` auth/routing/
edge-trigger/re-fire/pause/vault-not-set/threshold change.

## License

MIT — see [LICENSE](LICENSE).
