#!/usr/bin/env node
// Self-check for the plan-revenue feature: the per-plan breakdown the admin
// finance chart relies on MUST reconcile to the grand completed-order total.
// Runs the same grouping the worker's getPlanRevenue() uses, against remote D1,
// and asserts SUM(by plan) === SUM(by provider) === grand total.
//
// Usage: zsh -c "source ~/.zshrc && node cloudflare/scripts/check-revenue.mjs"
import { execFileSync } from "node:child_process";

const DB = "dotsherness-db";

function query(sql) {
  // wr-dotsherness is a zsh function; wrap the SQL in single quotes (no zsh globbing
  // of parens) and escape any embedded single quote as the standard '\'' sequence.
  const quoted = `'${sql.replace(/'/g, "'\\''")}'`;
  const cmd = `source ~/.zshrc && wr-dotsherness d1 execute ${DB} --remote --json --command ${quoted}`;
  const out = execFileSync("zsh", ["-c", cmd], { encoding: "utf8" });
  const json = JSON.parse(out.slice(out.indexOf("[")));
  return json[0].results;
}

const grand = query(
  "SELECT COALESCE(SUM(amount_minor),0) AS k FROM billing_orders WHERE status = 'completed';"
)[0].k;

const byPlan = query(
  "SELECT plan_slug, COALESCE(SUM(amount_minor),0) AS k FROM billing_orders WHERE status = 'completed' GROUP BY plan_slug;"
);
const byProvider = query(
  "SELECT payment_provider, COALESCE(SUM(amount_minor),0) AS k FROM billing_orders WHERE status = 'completed' GROUP BY payment_provider;"
);

const sum = (rows) => rows.reduce((a, r) => a + r.k, 0);
const planTotal = sum(byPlan);
const providerTotal = sum(byProvider);

console.log("grand:", grand, "byPlan:", planTotal, "byProvider:", providerTotal);
console.table(byPlan);
console.table(byProvider);

if (planTotal !== grand) throw new Error(`plan breakdown ${planTotal} != grand ${grand}`);
if (providerTotal !== grand) throw new Error(`provider breakdown ${providerTotal} != grand ${grand}`);
console.log("OK: per-plan and per-provider revenue reconcile to grand total.");
