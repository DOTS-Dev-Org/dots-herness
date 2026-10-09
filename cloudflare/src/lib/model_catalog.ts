// Copyright (c) 2026 DOTS
// Keeps the Claude entry of the published model catalog current. Claude
// subscription sign-in has no model listing the app can call, so the Worker
// asks the Anthropic API and prepends anything released since the newest
// model the catalog already lists. The rest of the catalog is published by
// scripts/publish-model-catalog.mjs and is left untouched.

import type { Env } from "../env";

const CATALOG_KEY = "catalog/models.json";

interface CatalogModel { id: string; name?: string; [key: string]: unknown }
interface CatalogEntry { id: string; models: CatalogModel[]; userAgent?: string }
interface AnthropicModel { id: string; display_name?: string; created_at?: string }

/** Models released after the newest one already listed, newest first. */
export function newClaudeModels(known: CatalogModel[], live: AnthropicModel[]): CatalogModel[] {
  const knownIds = known.map((model) => model.id);
  const released = (model: AnthropicModel) => Date.parse(model.created_at ?? "");
  const newestKnown = Math.max(...live.filter((model) => knownIds.includes(model.id)).map(released).filter(Number.isFinite));
  // No overlap means the listing is not comparable; never guess.
  if (!Number.isFinite(newestKnown)) return [];
  return live
    .filter((model) => released(model) > newestKnown)
    // A dated snapshot of an alias that is already listed is the same model.
    // Only a date suffix counts: "claude-fable-5-1" is not a snapshot of "claude-fable-5".
    .filter((model) => !knownIds.some((id) => model.id === id || (model.id.startsWith(`${id}-`) && /^\d{8}$/.test(model.id.slice(id.length + 1)))))
    .sort((a, b) => released(b) - released(a))
    .map((model) => ({ id: model.id, name: model.display_name }));
}

export async function syncClaudeCatalog(env: Env): Promise<void> {
  if (!env.ANTHROPIC_API_KEY) return;
  try {
    const stored = await env.DOTSHERNESS_ASSETS.get(CATALOG_KEY);
    if (!stored) return;
    const catalog = await stored.json<CatalogEntry[]>();
    const claude = catalog.find((entry) => entry.id === "claude");
    if (!claude) return;

    const response = await fetch("https://api.anthropic.com/v1/models?limit=1000", {
      headers: { "x-api-key": env.ANTHROPIC_API_KEY, "anthropic-version": "2023-06-01" },
    });
    if (!response.ok) throw new Error(`Anthropic models HTTP ${response.status}`);
    const { data } = await response.json<{ data: AnthropicModel[] }>();

    const added = newClaudeModels(claude.models, data ?? []);
    if (!added.length) return;
    claude.models = [...added, ...claude.models];
    await env.DOTSHERNESS_ASSETS.put(CATALOG_KEY, JSON.stringify(catalog), {
      httpMetadata: { contentType: "application/json" },
    });
    console.log(`model catalog: added ${added.map((model) => model.id).join(", ")}`);
  } catch (error) {
    console.error("model catalog sync failed", error);
  }
}
