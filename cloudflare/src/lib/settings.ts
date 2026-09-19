import type { Env } from "../env";
import { db } from "../db/client";

export class RegistrationClosedError extends Error {
  readonly code = "registration_closed";
  constructor() {
    super("Registration is closed");
  }
}

export function parseSettingBool(value: string | undefined | null, fallback: boolean): boolean {
  if (value == null || value === "") return fallback;
  const v = value.trim().toLowerCase();
  if (v === "true" || v === "1" || v === "yes") return true;
  if (v === "false" || v === "0" || v === "no") return false;
  return fallback;
}

export async function getSystemSettings(env: Env): Promise<Record<string, string>> {
  const { results } = await db(env)
    .prepare("SELECT key, value FROM system_settings")
    .all<{ key: string; value: string }>();
  const settings: Record<string, string> = {};
  for (const row of results ?? []) {
    settings[row.key] = row.value;
  }
  return settings;
}

export async function isRegistrationOpen(env: Env): Promise<boolean> {
  const row = await db(env)
    .prepare("SELECT value FROM system_settings WHERE key = 'registration_open'")
    .first<{ value: string }>();
  return parseSettingBool(row?.value, true);
}
