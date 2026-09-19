export type PlanSlug = "free" | "pro" | "team";

export type PlanFeatures = {
  watchNotifications: boolean;
  usageAnalytics: boolean;
  teamManagement: boolean;
};

/** In-code SaaS plan catalog — replaces dropped token_plans table. */
export type PlanDef = {
  slug: PlanSlug;
  name: string;
  max_providers: number;
  max_seats: number;
  /** USD cents / month */
  price_monthly_cents: number;
  /** USD cents / year */
  price_yearly_cents: number;
  extra_seat_price_monthly_cents: number;
  /** USD cents / year for one extra Team seat. 0 when the plan has no extra-seat add-on. */
  extra_seat_price_yearly_cents: number;
  /** Minimum allowed key/scan sync interval (seconds). Free & Pro: 5dk taban. */
  min_sync_interval_secs: number;
};

const FEATURES: Record<PlanSlug, PlanFeatures> = {
  free: {
    watchNotifications: true,
    usageAnalytics: false,
    teamManagement: false,
  },
  pro: {
    watchNotifications: true,
    usageAnalytics: true,
    teamManagement: false,
  },
  team: {
    watchNotifications: true,
    usageAnalytics: true,
    teamManagement: true,
  },
};

/** Canonical list prices + limits (was token_plans rows). */
export const PLAN_DEFS: Record<PlanSlug, PlanDef> = {
  free: {
    slug: "free",
    name: "Free",
    max_providers: 3,
    max_seats: 1,
    price_monthly_cents: 0,
    price_yearly_cents: 0,
    extra_seat_price_monthly_cents: 0,
    extra_seat_price_yearly_cents: 0,
    min_sync_interval_secs: 300,
  },
  pro: {
    slug: "pro",
    name: "Pro",
    max_providers: -1,
    max_seats: 1,
    price_monthly_cents: 99,
    price_yearly_cents: 999,
    extra_seat_price_monthly_cents: 0,
    extra_seat_price_yearly_cents: 0,
    min_sync_interval_secs: 300,
  },
  team: {
    slug: "team",
    name: "Team",
    max_providers: -1,
    max_seats: 3,
    price_monthly_cents: 499,
    price_yearly_cents: 4999,
    extra_seat_price_monthly_cents: 99,
    extra_seat_price_yearly_cents: 999,
    min_sync_interval_secs: 60,
  },
};

export const LISTED_PLAN_SLUGS: PlanSlug[] = ["free", "pro", "team"];

export function normalizePlanSlug(slug: string | null | undefined): PlanSlug {
  if (!slug) return "free";
  const s = slug.toLowerCase().replace(/^token-/, "");
  if (s === "pro" || s === "team") return s;
  // legacy slugs collapsed into free/pro/team
  if (s === "starter" || s === "free") return "free";
  if (s === "plus" || s === "business") return "team";
  return "free";
}

export function planDefForSlug(slug: string | null | undefined): PlanDef {
  return PLAN_DEFS[normalizePlanSlug(slug)];
}

export function planFeaturesForSlug(slug: string | null | undefined): PlanFeatures {
  return FEATURES[normalizePlanSlug(slug)];
}

export function isListedPlanSlug(slug: string): slug is PlanSlug {
  return LISTED_PLAN_SLUGS.includes(slug as PlanSlug);
}

export function listPlanDefs(): PlanDef[] {
  return LISTED_PLAN_SLUGS.map((s) => PLAN_DEFS[s]);
}
