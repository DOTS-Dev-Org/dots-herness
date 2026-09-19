/** Server key polling + extension browser scan intervals (seconds). */
export const ALLOWED_SYNC_INTERVALS = [
  5, 10, 15, 30, 60, 120, 300, 600, 1800, 3600,
] as const;
export type SyncIntervalSecs = (typeof ALLOWED_SYNC_INTERVALS)[number];

export const DEFAULT_SYNC_INTERVAL_SECS: SyncIntervalSecs = 600;

export function normalizeSyncInterval(secs: unknown): SyncIntervalSecs {
  const n = typeof secs === "number" ? secs : typeof secs === "string" ? parseInt(secs, 10) : NaN;
  if (ALLOWED_SYNC_INTERVALS.includes(n as SyncIntervalSecs)) {
    return n as SyncIntervalSecs;
  }
  return DEFAULT_SYNC_INTERVAL_SECS;
}

/** Clamps an interval up to the plan's minimum (e.g. free/pro taban 300sn, team 60sn). */
export function clampSyncIntervalToPlan(
  secs: SyncIntervalSecs,
  minSecs: number
): SyncIntervalSecs {
  if (secs >= minSecs) return secs;
  return (ALLOWED_SYNC_INTERVALS.find((s) => s >= minSecs) ?? DEFAULT_SYNC_INTERVAL_SECS) as SyncIntervalSecs;
}
