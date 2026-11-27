// Sentinel AI agent — publishes a DeFi risk score (0-100) to the RiskOracle
// on Base Sepolia. The Sentinel reactive contract on Lasna watches the oracle
// and triggers an emergency Vault withdrawal when the score crosses >= 80.
//
// Usage:
//   node agent.mjs              loop forever (POLL_INTERVAL_MS between checks)
//   node agent.mjs --once       a single cycle, then exit
//   node agent.mjs --demo       end-to-end pipeline demo with the mock provider:
//                               publish 30, wait, publish 85, then watch for the
//                               reactive callback to empty the Vault (up to 10 min)
//   node agent.mjs --score 85  publish a forced mock score once (demo/debug)
//
// Env (see .env.example): RPC_URL, ORACLE_ADDRESS, WALLET_KEY_PATH,
// SENTINEL_LLM_API_KEY / SENTINEL_LLM_BASE_URL / SENTINEL_LLM_MODEL.
// Without an LLM key the mock provider is used. The key is never hardcoded.

import { readFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { ethers } from 'ethers';
import { mockScore, llmScore } from './providers.mjs';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const ORACLE_ABI = [
  'function updateScore(uint256 score_, string reason_) external',
  'function latestScore() view returns (uint256)',
  'function latestReason() view returns (string)',
  'function latestUpdatedAt() view returns (uint256)',
  'event RiskScoreUpdated(uint256 score, uint256 updatedAt, string reason)',
];
const REACTIVE_ABI = [
  'function triggerCount() view returns (uint256)',
  'function lastScore() view returns (uint256)',
];
const VAULT_ABI = ['function safeAddress() view returns (address)'];

const REACTIVE_ADDRESS = '0x56059b33912670C050c88393085836A43ef738AC';
const VAULT_ADDRESS = '0x04c66C1dEBBa7913833dF445f3dB290bfDC77032';
const LASNA_RPC = 'https://lasna-rpc.rnk.dev/';

function loadEnv() {
  const envPath = join(dirname(fileURLToPath(import.meta.url)), '.env');
  if (!existsSync(envPath)) return;
  for (const line of readFileSync(envPath, 'utf8').split('\n')) {
    const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/);
    if (m && !process.env[m[1]]) process.env[m[1]] = m[2];
  }
}
loadEnv();

const cfg = {
  rpcUrl: process.env.RPC_URL ?? 'https://base-sepolia-rpc.publicnode.com',
  oracle: process.env.ORACLE_ADDRESS ?? '0xdc4e2FD88491C69058509fFb5638EF2D266f0C7e',
  walletKeyPath: process.env.WALLET_KEY_PATH ?? join(ROOT, 'wallet-testnet.json'),
  llmApiKey: process.env.SENTINEL_LLM_API_KEY ?? '',
  llmBaseUrl: process.env.SENTINEL_LLM_BASE_URL ?? 'https://api.groq.com/openai/v1',
  llmModel: process.env.SENTINEL_LLM_MODEL ?? 'qwen/qwen3.8-27b',
  pollMs: Number(process.env.POLL_INTERVAL_MS ?? 300000),
};
const useLlm = Boolean(cfg.llmApiKey);
console.log(`[sentinel] provider: ${useLlm ? `LLM (${cfg.llmModel} @ ${cfg.llmBaseUrl})` : 'mock (no SENTINEL_LLM_API_KEY set)'}`);
console.log(`[sentinel] oracle: ${cfg.oracle} on Base Sepolia`);

const provider = new ethers.JsonRpcProvider(cfg.rpcUrl);
const keyJson = JSON.parse(readFileSync(cfg.walletKeyPath, 'utf8'));
const wallet = new ethers.Wallet(keyJson[0].private_key, provider);
const oracle = new ethers.Contract(cfg.oracle, ORACLE_ABI, wallet);
console.log(`[sentinel] agent wallet: ${wallet.address}`);

async function fetchPrice() {
  const res = await fetch(
    'https://api.coingecko.com/api/v3/simple/price?ids=ethereum&vs_currencies=usd&include_24hr_change=true',
    { headers: { accept: 'application/json' } },
  );
  if (!res.ok) throw new Error(`CoinGecko HTTP ${res.status}`);
  const data = await res.json();
  const eth = data.ethereum;
  return { usd: eth.usd, change24hPct: eth.usd_24h_change ?? 0 };
}

async function scorePrice(price) {
  if (useLlm) {
    return await llmScore(price, {
      apiKey: cfg.llmApiKey,
      baseUrl: cfg.llmBaseUrl,
      model: cfg.llmModel,
    });
  }
  return mockScore(price);
}

async function publish(score, reason) {
  const tx = await oracle.updateScore(score, reason);
  console.log(`[sentinel] updateScore(${score}) tx: ${tx.hash}`);
  const receipt = await tx.wait();
  console.log(`[sentinel] confirmed in block ${receipt.blockNumber} (status ${receipt.status})`);
  return tx.hash;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function oneCycle(forcedScore = null) {
  const price = await fetchPrice();
  console.log(`[sentinel] ETH/USD $${price.usd.toFixed(2)} (24h ${price.change24hPct.toFixed(2)}%)`);
  const { score, reason } =
    forcedScore !== null
      ? { score: forcedScore, reason: `Forced demo score ${forcedScore}.` }
      : await scorePrice(price);
  console.log(`[sentinel] risk score ${score} — ${reason}`);
  const prev = Number(await oracle.latestScore());
  if (prev === score) {
    console.log(`[sentinel] score unchanged (${prev}), skipping on-chain write.`);
    return { score, txHash: null };
  }
  const txHash = await publish(score, reason);
  return { score, txHash };
}

async function watchWithdrawal(timeoutMs = 600_000) {
  const lasna = new ethers.JsonRpcProvider(LASNA_RPC);
  const reactive = new ethers.Contract(REACTIVE_ADDRESS, REACTIVE_ABI, lasna);
  const vault = new ethers.Contract(VAULT_ADDRESS, VAULT_ABI, provider);
  const safe = await vault.safeAddress();
  const startTriggers = Number(await reactive.triggerCount());
  const startBalance = await provider.getBalance(VAULT_ADDRESS);
  console.log(`[demo] start: triggerCount=${startTriggers}, vault=${ethers.formatEther(startBalance)} ETH, safe=${safe}`);
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const triggers = Number(await reactive.triggerCount());
    const balance = await provider.getBalance(VAULT_ADDRESS);
    const safeBalance = await provider.getBalance(safe);
    console.log(`[demo] poll: triggerCount=${triggers}, vault=${ethers.formatEther(balance)} ETH, safe=${ethers.formatEther(safeBalance)} ETH`);
    if (triggers > startTriggers && balance < startBalance) {
      console.log('[demo] SUCCESS: reactive contract fired and the Vault was emergency-withdrawn.');
      return true;
    }
    await sleep(20_000);
  }
  console.log('[demo] TIMEOUT: no callback observed within 10 minutes. Check Reactscan + reactive contract balance/debt.');
  return false;
}

const args = process.argv.slice(2);
if (args.includes('--demo')) {
  console.log('[demo] end-to-end pipeline demo (mock provider, forced scores 30 -> 85)');
  await oneCycle(30);
  console.log('[demo] waiting 20s before the high score...');
  await sleep(20_000);
  await oneCycle(85);
  const ok = await watchWithdrawal();
  process.exit(ok ? 0 : 1);
} else if (args.includes('--score')) {
  const forced = Number(args[args.indexOf('--score') + 1]);
  if (!Number.isFinite(forced) || forced < 0 || forced > 100) {
    console.error('usage: node agent.mjs --score <0-100>');
    process.exit(2);
  }
  await oneCycle(forced);
  process.exit(0);
} else if (args.includes('--once')) {
  await oneCycle();
  process.exit(0);
} else {
  for (;;) {
    try {
      await oneCycle();
    } catch (err) {
      console.error(`[sentinel] cycle failed: ${err.message}`);
    }
    await sleep(cfg.pollMs);
  }
}
