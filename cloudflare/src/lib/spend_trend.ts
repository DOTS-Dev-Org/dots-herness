export type SubscriptionHistoryInput = {
  provider_id: string;
  price_usd_cents: number | null;
  plan_name: string | null;
  source: string | null;
  observed_at: string;
};

function normalizeProviderId(providerId: string): string {
  return providerId.toLowerCase().trim();
}

export type SpendIncrement = {
  providerId: string;
  observedAt: string;
  incrementCents: number;
};

export type SpendTrendBucket = {
  key: string;
  label: string;
  startIso: string;
  endIso: string;
};

export type SpendTrendPointInput = {
  key: string;
  label: string;
  spendUsdCents: number;
};

function priceCents(row: SubscriptionHistoryInput): number {
  return row.price_usd_cents ?? 0;
}

function providerConnectedAt(
  connectedAtByProvider: Map<string, string>,
  providerId: string,
  observedAt: string
): boolean {
  const created = connectedAtByProvider.get(normalizeProviderId(providerId));
  if (!created) return false;
  return new Date(created).getTime() <= new Date(observedAt).getTime();
}

/** Tek-seferlik harcama artışları: ilk ekleme tam tutar, yükseltme delta. */
export function computeSpendIncrements(
  rows: SubscriptionHistoryInput[],
  connectedAtByProvider: Map<string, string>
): SpendIncrement[] {
  const byProvider = new Map<string, SubscriptionHistoryInput[]>();
  for (const row of rows) {
    const providerId = normalizeProviderId(row.provider_id);
    if (!connectedAtByProvider.has(providerId)) continue;
    const list = byProvider.get(providerId) || [];
    list.push(row);
    byProvider.set(providerId, list);
  }

  const increments: SpendIncrement[] = [];

  for (const [providerId, providerRows] of byProvider) {
    const sorted = [...providerRows].sort(
      (a, b) => new Date(a.observed_at).getTime() - new Date(b.observed_at).getTime()
    );

    let lastPrice = 0;

    for (const row of sorted) {
      if (row.source === "needs_desktop") continue;
      if (!providerConnectedAt(connectedAtByProvider, providerId, row.observed_at)) continue;

      const price = priceCents(row);
      if (price <= 0) continue;

      let incrementCents = 0;
      if (lastPrice <= 0) {
        incrementCents = price;
      } else if (price > lastPrice) {
        incrementCents = price - lastPrice;
      }

      lastPrice = price;

      if (incrementCents > 0) {
        increments.push({
          providerId,
          observedAt: row.observed_at,
          incrementCents,
        });
      }
    }
  }

  return increments.sort(
    (a, b) => new Date(a.observedAt).getTime() - new Date(b.observedAt).getTime()
  );
}

/** Artışları ilgili zaman bucket'ına ata (her olay yalnızca bir bucket'ta). */
export function assignIncrementsToBuckets(
  increments: SpendIncrement[],
  buckets: SpendTrendBucket[]
): SpendTrendPointInput[] {
  const spendByKey = new Map<string, number>();
  for (const bucket of buckets) {
    spendByKey.set(bucket.key, 0);
  }

  for (const inc of increments) {
    const t = new Date(inc.observedAt).getTime();
    for (const bucket of buckets) {
      const startMs = new Date(bucket.startIso).getTime();
      const endMs = new Date(bucket.endIso).getTime();
      if (t >= startMs && t <= endMs) {
        spendByKey.set(bucket.key, (spendByKey.get(bucket.key) ?? 0) + inc.incrementCents);
        break;
      }
    }
  }

  return buckets.map((bucket) => ({
    key: bucket.key,
    label: bucket.label,
    spendUsdCents: spendByKey.get(bucket.key) ?? 0,
  }));
}

export function buildSpendTrendPoints(
  historyRows: SubscriptionHistoryInput[],
  connectedAtByProvider: Map<string, string>,
  buckets: SpendTrendBucket[]
): SpendTrendPointInput[] {
  const increments = computeSpendIncrements(historyRows, connectedAtByProvider);
  return assignIncrementsToBuckets(increments, buckets);
}
