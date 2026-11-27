// Providers: mock (rule-based, no key needed) and LLM (OpenAI-compatible chat
// completions — Groq free tier by default). The LLM call is behind env config;
// without SENTINEL_LLM_API_KEY the agent always uses the mock provider.

const SYSTEM_PROMPT = `You are a DeFi risk analyst for an automated guardian. Given the ETH/USD price, 24h change and recent volatility, return a risk score from 0 (safe) to 100 (extreme danger) plus a one-sentence reason. A score of 80 or above triggers an automatic emergency withdrawal of guarded funds, so reserve 80+ for genuinely dangerous conditions (sharp crash, extreme volatility). Respond with JSON only: {"score": <number>, "reason": "<one sentence>"}.`;

/** Rule-based fallback: score purely from the 24h price change. */
export function mockScore(price) {
  const chg = price.change24hPct;
  if (chg <= -5) return { score: 85, reason: `Mock: ETH down ${chg.toFixed(2)}% in 24h — sharp drop, high risk.` };
  if (chg <= -2) return { score: 65, reason: `Mock: ETH down ${chg.toFixed(2)}% in 24h — elevated risk.` };
  if (chg < 0) return { score: 45, reason: `Mock: ETH down ${chg.toFixed(2)}% in 24h — mild pressure.` };
  if (chg <= 2) return { score: 25, reason: `Mock: ETH up ${chg.toFixed(2)}% in 24h — calm market.` };
  return { score: 20, reason: `Mock: ETH up ${chg.toFixed(2)}% in 24h — calm market.` };
}

/** Call an OpenAI-compatible LLM for the risk score. */
export async function llmScore(price, { apiKey, baseUrl, model }) {
  const user = `ETH/USD price: $${price.usd.toFixed(2)}. 24h change: ${price.change24hPct.toFixed(2)}%. ` +
    `Assess the risk to funds held in a DeFi vault right now.`;
  const res = await fetch(`${baseUrl.replace(/\/$/, '')}/chat/completions`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${apiKey}`,
    },
    body: JSON.stringify({
      model,
      messages: [
        { role: 'system', content: SYSTEM_PROMPT },
        { role: 'user', content: user },
      ],
      temperature: 0.2,
      response_format: { type: 'json_object' },
    }),
  });
  if (!res.ok) {
    const body = await res.text().catch(() => '');
    throw new Error(`LLM HTTP ${res.status}: ${body.slice(0, 300)}`);
  }
  const data = await res.json();
  const text = data.choices?.[0]?.message?.content ?? '';
  const parsed = JSON.parse(text);
  const score = Math.max(0, Math.min(100, Math.round(Number(parsed.score))));
  if (!Number.isFinite(score)) throw new Error(`LLM returned non-numeric score: ${text.slice(0, 200)}`);
  return { score, reason: String(parsed.reason ?? '').slice(0, 200) || 'LLM score, no reason given.' };
}
