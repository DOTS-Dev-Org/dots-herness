#!/usr/bin/env node
// One-off: existing usernames must satisfy USERNAME_REGEX (lib/users.ts) —
// lowercase ascii [a-z0-9_-]{3,32}, no spaces/Turkish chars. Legacy rows
// predate that constraint. Transliterates Turkish letters, strips the rest,
// dedupes collisions with a numeric suffix, then writes/executes the UPDATEs.
//
// Usage:
//   node cloudflare/scripts/normalize-usernames.mjs           # dry run, prints plan
//   node cloudflare/scripts/normalize-usernames.mjs --apply --local
//   node cloudflare/scripts/normalize-usernames.mjs --apply --remote
import { execFileSync } from "node:child_process";

const DB = "dotsherness-db";
const args = process.argv.slice(2);
const apply = args.includes("--apply");
const target = args.includes("--remote") ? "--remote" : "--local";

function query(sql) {
  const quoted = `'${sql.replace(/'/g, "'\\''")}'`;
  const cmd = `source ~/.zshrc && wr-dotsherness d1 execute ${DB} ${target} --json --command ${quoted}`;
  const out = execFileSync("zsh", ["-c", cmd], { encoding: "utf8" });
  const json = JSON.parse(out.slice(out.indexOf("[")));
  return json[0].results;
}

function exec(sql) {
  const quoted = `'${sql.replace(/'/g, "'\\''")}'`;
  const cmd = `source ~/.zshrc && wr-dotsherness d1 execute ${DB} ${target} --json --command ${quoted}`;
  execFileSync("zsh", ["-c", cmd], { encoding: "utf8" });
}

const TR_MAP = {
  ş: "s", Ş: "s", ğ: "g", Ğ: "g", ü: "u", Ü: "u",
  ö: "o", Ö: "o", ç: "c", Ç: "c", ı: "i", İ: "i",
};

function normalize(raw, taken) {
  let base = raw
    .replace(/[şŞğĞüÜöÖçÇıİ]/g, (ch) => TR_MAP[ch])
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9_-]/g, "");
  if (base.length < 3) base = `user${base}`.slice(0, 32) || "user";
  base = base.slice(0, 32);

  let candidate = base;
  let i = 1;
  while (taken.has(candidate)) {
    i += 1;
    candidate = `${base}${i}`.slice(0, 32);
  }
  taken.add(candidate);
  return candidate;
}

const rows = query("SELECT id, username, email FROM users;");

const VALID = /^[a-z0-9_-]{3,32}$/;
const taken = new Set(
  rows.map((r) => r.username).filter((u) => u && VALID.test(u)).map((u) => u.toLowerCase())
);
const changes = [];

for (const row of rows) {
  if (row.username && VALID.test(row.username)) continue; // already compliant
  const seed = row.username && row.username.trim() ? row.username : row.email.split("@")[0];
  const next = normalize(seed, taken);
  changes.push({ id: row.id, from: row.username ?? "(null)", to: next });
}

if (changes.length === 0) {
  console.log("No non-compliant usernames found.");
  process.exit(0);
}

console.table(changes);

if (!apply) {
  console.log(`Dry run (${target}). Re-run with --apply --local|--remote to write.`);
  process.exit(0);
}

for (const c of changes) {
  exec(`UPDATE users SET username = '${c.to}' WHERE id = '${c.id}';`);
}
console.log(`Updated ${changes.length} row(s) on ${target}.`);
