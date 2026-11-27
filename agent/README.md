# Sentinel agent

Off-chain AI risk scorer for the Sentinel build (Reactive Omni Buildathon,
Track 3 "Reactive Meets AI"). It reads ETH/USD, asks an LLM for a risk score
0-100, and publishes the score to the RiskOracle on Base Sepolia. The
Sentinel reactive contract on Lasna watches the oracle and triggers an
emergency Vault withdrawal when the score crosses >= 80.

## Run

```bash
npm install
cp .env.example .env   # no key needed for the mock provider
node agent.mjs --once  # single cycle
node agent.mjs         # loop every POLL_INTERVAL_MS (default 5 min)
node agent.mjs --demo  # end-to-end demo: publish 30, then 85, watch the Vault
node agent.mjs --score 85  # publish a forced mock score once
```

## LLM provider (pluggable)

Set in `.env` (never commit a real key):

- `SENTINEL_LLM_API_KEY` — if unset, the built-in mock provider is used
  (rule-based score from the 24h price change).
- `SENTINEL_LLM_BASE_URL` — default `https://api.groq.com/openai/v1`
  (Groq free tier, OpenAI-compatible).
- `SENTINEL_LLM_MODEL` — default `qwen/qwen3.8-27b`.

## Deployed contracts (testnet)

- RiskOracle (Base Sepolia):
  `0xdc4e2FD88491C69058509fFb5638EF2D266f0C7e`
- SentinelReactive (Lasna):
  `0x56059b33912670C050c88393085836A43ef738AC`
- Vault (Base Sepolia):
  `0x04c66C1dEBBa7913833dF445f3dB290bfDC77032`
