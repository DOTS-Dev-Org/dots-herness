#!/usr/bin/env node
/**
 * Read-only remote verification for the versioned legal-document import.
 *
 * The check reads the expected 60 D1 rows, downloads each immutable R2 object
 * to a temporary directory, and compares its SHA-256 with the D1 hash. It
 * never writes to D1 or R2 and never prints document bodies.
 */

import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDirectory = resolve(fileURLToPath(new URL(".", import.meta.url)));
const repositoryRoot = resolve(scriptDirectory, "../..");
const manifestPath = join(repositoryRoot, "mobile/localization/languages.json");
const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
const locales = manifest.languages.map((item) => item.code).filter((code) => code !== "system");
const documentNames = ["terms", "privacy_notice"];
const version = valueArg("--version", "2026-08-26");
const wrangler = process.env.HERNESS_WRANGLER_BIN || "wr-dotsherness";
const bucket = process.env.HERNESS_LEGAL_BUCKET || "dotsherness-assets";
const database = process.env.HERNESS_LEGAL_DATABASE || "dotsherness-db";

function valueArg(name, fallback) {
  const prefix = `${name}=`;
  const found = process.argv.slice(2).find((value) => value.startsWith(prefix));
  return found ? found.slice(prefix.length) : fallback;
}

function shellQuote(value) {
  return `'${String(value).replaceAll("'", `'\\''`)}'`;
}

function runWrangler(commandArguments) {
  const command = [wrangler, ...commandArguments.map(shellQuote)].join(" ");
  return execFileSync("zsh", ["-ic", command], {
    cwd: repositoryRoot,
    encoding: "utf8",
    env: process.env,
    stdio: ["ignore", "pipe", "pipe"],
  });
}

function parseWranglerJSON(output) {
  const start = output.indexOf("[");
  if (start < 0) throw new Error("Wrangler did not return JSON output");
  return JSON.parse(output.slice(start));
}

function queryRows() {
  const sql = [
    "SELECT locale, document_key, version, sha256, r2_key, translation_status",
    "FROM legal_documents",
    "WHERE app_slug = 'dots-herness'",
    `AND version = '${version.replaceAll("'", "''")}'`,
    "ORDER BY locale, document_key;",
  ].join(" ");
  const output = runWrangler(["d1", "execute", database, "--remote", "--json", "--command", sql]);
  const payload = parseWranglerJSON(output);
  return payload[0]?.results || [];
}

function sha256File(path) {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

function expectedKeys() {
  return new Set(locales.flatMap((locale) => documentNames.map((documentKey) => `${locale}/${documentKey}`)));
}

function validateRows(rows) {
  const expected = expectedKeys();
  const seen = new Set();
  for (const row of rows) {
    const key = `${row.locale}/${row.document_key}`;
    if (!expected.has(key)) throw new Error(`unexpected D1 legal row: ${key}`);
    if (seen.has(key)) throw new Error(`duplicate D1 legal row: ${key}`);
    seen.add(key);
    if (row.version !== version) throw new Error(`version mismatch for ${key}`);
    if (!/^[a-f0-9]{64}$/.test(row.sha256 || "")) throw new Error(`invalid D1 SHA-256 for ${key}`);
    const expectedR2Key = `legal/dots-herness/${version}/${row.locale}/${row.document_key === "privacy_notice" ? "privacy-notice" : "terms"}.md`;
    if (row.r2_key !== expectedR2Key) throw new Error(`R2 key mismatch for ${key}: ${row.r2_key}`);
  }
  if (rows.length !== expected.size) throw new Error(`expected ${expected.size} D1 rows, got ${rows.length}`);
  if (seen.size !== expected.size) throw new Error(`expected ${expected.size} unique D1 rows, got ${seen.size}`);
}

function readbackObjects(rows, directory) {
  for (const row of rows) {
    const safeName = `${row.locale}-${row.document_key}.md`.replace(/[^A-Za-z0-9._-]/g, "_");
    const outputPath = join(directory, safeName);
    runWrangler(["r2", "object", "get", `${bucket}/${row.r2_key}`, "--remote", "--file", outputPath]);
    if (!existsSync(outputPath)) throw new Error(`R2 object was not written to the readback file: ${row.r2_key}`);
    const actualHash = sha256File(outputPath);
    const key = `${row.locale}/${row.document_key}`;
    if (actualHash !== row.sha256) throw new Error(`R2/D1 SHA-256 mismatch for ${key}`);
  }
}

function main() {
  if (process.argv.includes("--help")) {
    console.log("usage: node cloudflare/scripts/readback-legal-documents.mjs [--version=VERSION]");
    return;
  }
  const rows = queryRows();
  validateRows(rows);
  const directory = mkdtempSync(join(tmpdir(), "herness-legal-readback-"));
  try {
    readbackObjects(rows, directory);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
  console.log(`OK: ${rows.length} D1 rows and ${rows.length} R2 objects verified for ${version}.`);
}

try {
  main();
} catch (error) {
  console.error(error instanceof Error ? error.message : error);
  process.exitCode = 1;
}
