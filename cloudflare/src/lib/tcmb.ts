import type { Env } from "../env";

const TCMB_XML_URL = "https://www.tcmb.gov.tr/kurlar/today.xml";

export type UsdTryRate = {
  usd_try: number;
  date: string | null;
  source: string;
  fetched_at: string;
  stale: boolean;
};

function parseTcmbXml(xmlText: string) {
  const usdMatch = xmlText.match(/<Currency[^>]*KOD="USD"[^>]*>([\s\S]*?)<\/Currency>/i);
  if (!usdMatch) return null;
  const inner = usdMatch[1];
  const buyMatch = inner.match(/<ForexBuying>([\d.,]+)<\/ForexBuying>/i);
  const sellMatch = inner.match(/<ForexSelling>([\d.,]+)<\/ForexSelling>/i);
  const dateMatch = xmlText.match(/<Tarih[^>]*date="([^"]+)"/i) || xmlText.match(/<Tarih[^>]*>([\d.]+)<\/Tarih>/i);
  const buy = buyMatch ? parseFloat(buyMatch[1].replace(",", ".")) : null;
  const sell = sellMatch ? parseFloat(sellMatch[1].replace(",", ".")) : null;
  const usdTry = buy ?? sell;
  if (usdTry == null) return null;
  return {
    usd_try: usdTry,
    date: dateMatch ? dateMatch[1] || null : null,
    source: "tcmb.gov.tr",
    fetched_at: new Date().toISOString(),
    stale: false,
  };
}

async function fetchTcmbLive() {
  try {
    const r = await fetch(TCMB_XML_URL, { cf: { cacheTtl: 1800 } } as RequestInit);
    if (!r.ok) return null;
    return parseTcmbXml(await r.text());
  } catch {
    return null;
  }
}

export async function getUsdTryRate(env: Env) {
  const live = await fetchTcmbLive();
  if (live) return live;

  return { usd_try: 32.0, date: null, source: "fallback", fetched_at: new Date().toISOString(), stale: true };
}

export function isUsablePaymentRate(rate: UsdTryRate): boolean {
  return rate.stale !== true && Number.isFinite(rate.usd_try) && rate.usd_try > 0;
}
