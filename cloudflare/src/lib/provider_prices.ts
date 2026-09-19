/**
 * Resolve list price for a provider plan name from subscription_packets.
 * Scraped names are short ("Pro", "Max 5x", "Token Plan · Monthly Plus");
 * catalog labels are full ("Claude Pro", "MiniMax Token Plan Plus").
 */

export type SubscriptionPacketRow = {
  provider_id: string;
  plan_slug: string;
  plan_label: string;
  price_usd_cents: number;
};

/** @deprecated Use SubscriptionPacketRow */
export type ProviderPlanPriceRow = SubscriptionPacketRow;

/** Collapse punctuation / filler so "Token Plan · Monthly Plus" ≈ "plus". */
export function normalizePlanKey(raw: string): string {
  return raw
    .toLowerCase()
    .normalize("NFKD")
    .replace(/[^\w\s+x]/g, " ")
    .replace(/\b(monthly|yearly|annual|annually|subscription|plan|token|the|a|an)\b/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function tokens(s: string): string[] {
  return normalizePlanKey(s).split(" ").filter(Boolean);
}

/** Score how well planName matches a catalog row (higher = better). 0 = no match. */
export function scorePlanMatch(planName: string, row: SubscriptionPacketRow): number {
  const name = normalizePlanKey(planName);
  if (!name) return 0;

  const label = normalizePlanKey(row.plan_label);
  const slug = normalizePlanKey(row.plan_slug.replace(/[_-]/g, " "));

  if (name === label || name === slug) return 100;
  if (label === name || slug === name) return 100;

  // "pro" ↔ "claude pro", "max 5x" ↔ "claude max 5x"
  if (label.endsWith(" " + name) || name.endsWith(" " + label)) return 90;
  if (slug.endsWith(" " + name) || name.endsWith(" " + slug)) return 88;

  // slug without spaces: max5x / max_5x
  const slugCompact = row.plan_slug.toLowerCase().replace(/[^a-z0-9+x]/g, "");
  const nameCompact = name.replace(/\s+/g, "");
  if (slugCompact && (slugCompact === nameCompact || nameCompact.includes(slugCompact) || slugCompact.includes(nameCompact))) {
    return 85;
  }

  const nameTok = tokens(planName);
  const labelTok = tokens(row.plan_label);
  const slugTok = tokens(row.plan_slug.replace(/[_-]/g, " "));

  // All name tokens appear in label (order-independent): "monthly plus" → "minimax ... plus"
  if (nameTok.length > 0 && nameTok.every((t) => labelTok.includes(t) || slugTok.includes(t))) {
    return 70 + Math.min(nameTok.length, 10);
  }

  // Last significant token: "Pro", "Plus", "Ultra"
  const lastName = nameTok[nameTok.length - 1];
  const lastLabel = labelTok[labelTok.length - 1];
  const lastSlug = slugTok[slugTok.length - 1];
  if (lastName && (lastName === lastLabel || lastName === lastSlug) && nameTok.length === 1) {
    return 60;
  }

  // Contains
  if (label.includes(name) || name.includes(label)) return 40;
  if (slug && (slug.includes(name) || name.includes(slug))) return 35;

  return 0;
}

export function resolveCatalogPrice(
  planName: string | null | undefined,
  catalog: SubscriptionPacketRow[]
): number | null {
  if (!planName || catalog.length === 0) return null;

  let best: SubscriptionPacketRow | null = null;
  let bestScore = 0;
  for (const row of catalog) {
    const score = scorePlanMatch(planName, row);
    if (score > bestScore) {
      bestScore = score;
      best = row;
    }
  }
  // Require a real signal; free tier (0¢) is valid when matched.
  if (!best || bestScore < 40) return null;
  return best.price_usd_cents;
}

/**
 * Effective monthly price: manual override wins; else catalog by plan name;
 * else provider.default_price_usd_cents.
 * Stored 0 is treated as unset (legacy).
 */
export function resolveEffectivePriceUsdCents(opts: {
  storedPriceUsdCents: number | null | undefined;
  planName: string | null | undefined;
  catalog: SubscriptionPacketRow[];
  defaultPriceUsdCents?: number | null;
}): number | null {
  const stored = opts.storedPriceUsdCents;
  if (stored != null && stored > 0) return stored;

  const fromCatalog = resolveCatalogPrice(opts.planName, opts.catalog);
  if (fromCatalog != null) return fromCatalog;

  const def = opts.defaultPriceUsdCents;
  if (def != null && def > 0) return def;
  return fromCatalog === 0 ? 0 : null;
}
