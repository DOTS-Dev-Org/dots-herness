#!/usr/bin/env node
/**
 * Import versioned HerNess legal Markdown into R2 and D1.
 *
 * This intentionally has no HTTP write path.  It performs all validation
 * before the first remote write, uploads immutable R2 keys, then upserts the
 * matching D1 rows.  Existing TR/EN content can be read from the public legacy
 * record; additional locale files must be supplied by the legal translation
 * workflow and are stored as draft unless explicitly promoted by an operator.
 */

import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDirectory = resolve(fileURLToPath(new URL(".", import.meta.url)));
const repositoryRoot = resolve(scriptDirectory, "../..");
const manifestPath = join(repositoryRoot, "mobile/localization/languages.json");
const defaultSourceUrl = "https://dots-web-api.pettakip.workers.dev/rest/v1/apps?select=privacy_policy_tr,privacy_policy_en,terms_of_service_tr,terms_of_service_en&slug.eq=dots-herness&single=true";
const defaultVersion = "2026-08-26";
const appSlug = "dots-herness";

const args = new Set(process.argv.slice(2));
const valueArg = (name, fallback) => {
  const prefix = `${name}=`;
  const found = process.argv.slice(2).find((value) => value.startsWith(prefix));
  return found ? found.slice(prefix.length) : fallback;
};

const version = valueArg("--version", defaultVersion);
const sourceUrl = valueArg("--source-url", defaultSourceUrl);
const sourceDir = valueArg("--source-dir", "");
const draftsDir = valueArg("--drafts-dir", join(repositoryRoot, "docs/legal/dots-herness", version));
const wrangler = process.env.HERNESS_WRANGLER_BIN || "wr-dotsherness";
const bucket = process.env.HERNESS_LEGAL_BUCKET || "dotsherness-assets";
const database = process.env.HERNESS_LEGAL_DATABASE || "dotsherness-db";

const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
const locales = manifest.languages.map((item) => item.code);
const requiredLocales = ["tr", "en", ...locales.filter((locale) => locale !== "tr" && locale !== "en")];
const documentNames = ["terms", "privacy-notice"];

function usage(message) {
  if (message) console.error(`error: ${message}`);
  console.error(`usage: node cloudflare/scripts/seed-legal-documents.mjs [--remote] [--source-dir=DIR] [--drafts-dir=DIR] [--version=VERSION]`);
  process.exit(2);
}

function hash(value) {
  return createHash("sha256").update(value, "utf8").digest("hex");
}

function sqlString(value) {
  return `'${String(value).replaceAll("'", "''")}'`;
}

function runWrangler(commandArguments) {
  // The project alias is a shell wrapper on some developer machines, hence
  // zsh -ic.  No credential or token is interpolated here.
  return execFileSync("zsh", ["-ic", [wrangler, ...commandArguments.map(shellQuote)].join(" ")], {
    cwd: repositoryRoot,
    stdio: "inherit",
    env: process.env,
  });
}

function shellQuote(value) {
  return `'${String(value).replaceAll("'", `'\\''`)}'`;
}

async function fetchLegacySource() {
  const response = await fetch(sourceUrl, { headers: { "User-Agent": "HerNessLegalImporter/1" } });
  if (!response.ok) throw new Error(`legacy legal source returned HTTP ${response.status}`);
  const root = await response.json();
  const row = root?.data && !Array.isArray(root.data) ? root.data : Array.isArray(root?.data) ? root.data[0] : root;
  if (!row || typeof row !== "object") throw new Error("legacy legal source did not return an object");
  const result = {
    tr: { terms: row.terms_of_service_tr, "privacy-notice": row.privacy_policy_tr },
    en: { terms: row.terms_of_service_en, "privacy-notice": row.privacy_policy_en },
  };
  for (const locale of ["tr", "en"]) {
    for (const documentName of documentNames) {
      if (typeof result[locale][documentName] !== "string" || !result[locale][documentName]) {
        throw new Error(`legacy legal source is missing ${locale}/${documentName}.md`);
      }
    }
  }
  return result;
}

function readMarkdownFile(directory, locale, documentName) {
  const path = join(directory, locale, `${documentName}.md`);
  if (!existsSync(path)) return null;
  const body = readFileSync(path, "utf8");
  if (!body.trim()) throw new Error(`${path} is empty`);
  return body;
}

async function collectDocuments() {
  const documents = {};
  const legacy = await fetchLegacySource();
  for (const locale of requiredLocales) {
    documents[locale] = {};
    for (const documentName of documentNames) {
      const supplied = sourceDir ? readMarkdownFile(resolve(sourceDir), locale, documentName) : null;
      const existing = legacy[locale]?.[documentName] || null;
      const draft = locale !== "tr" && locale !== "en" ? readMarkdownFile(resolve(draftsDir), locale, documentName) : null;
      const body = supplied || existing || draft;
      if (!body) {
        throw new Error(`missing ${locale}/${documentName}.md; provide --drafts-dir=${draftsDir}`);
      }
      const sourceLocale = locale === "tr" || locale === "en" ? locale : "en";
      const status = locale === "tr" || locale === "en" ? "published" : "draft";
      documents[locale][documentName] = { body, sourceLocale, status, sha256: hash(body) };
    }
  }
  return documents;
}

function sqlFor(documents, createdAt) {
  const lines = [
    "BEGIN TRANSACTION;",
    "INSERT INTO legal_documents (app_slug, document_key, locale, version, body_markdown, sha256, r2_key, translation_status, source_locale, created_at, published_at) VALUES",
  ];
  const rows = [];
  for (const locale of requiredLocales) {
    for (const documentName of documentNames) {
      const item = documents[locale][documentName];
      const key = documentName === "privacy-notice" ? "privacy_notice" : "terms";
      const r2Key = `legal/${appSlug}/${version}/${locale}/${documentName}.md`;
      const publishedAt = item.status === "draft" ? "NULL" : sqlString(createdAt);
      rows.push(`  (${sqlString(appSlug)}, ${sqlString(key)}, ${sqlString(locale)}, ${sqlString(version)}, ${sqlString(item.body)}, ${sqlString(item.sha256)}, ${sqlString(r2Key)}, ${sqlString(item.status)}, ${sqlString(item.sourceLocale)}, ${sqlString(createdAt)}, ${publishedAt})`);
    }
  }
  lines.push(rows.join(",\n"));
  lines.push("ON CONFLICT(app_slug, document_key, locale, version) DO UPDATE SET body_markdown=excluded.body_markdown, sha256=excluded.sha256, r2_key=excluded.r2_key, translation_status=excluded.translation_status, source_locale=excluded.source_locale, published_at=excluded.published_at;");
  lines.push("COMMIT;");
  return lines.join("\n");
}

function validate(documents) {
  const count = requiredLocales.length * documentNames.length;
  if (count !== 60) throw new Error(`expected 60 legal documents, got ${count}`);
  for (const locale of requiredLocales) {
    for (const documentName of documentNames) {
      const item = documents[locale]?.[documentName];
      if (!item || !/^[a-f0-9]{64}$/.test(item.sha256)) throw new Error(`invalid document ${locale}/${documentName}`);
      if (locale === "tr" && item.sourceLocale !== "tr") throw new Error("Turkish master source must remain tr");
    }
  }
}

async function main() {
  if (args.has("--help")) usage();
  if (!/^\d{4}-\d{2}-\d{2}(?:[._-][A-Za-z0-9]+)?$/.test(version)) usage(`invalid version: ${version}`);
  const documents = await collectDocuments();
  validate(documents);
  const createdAt = new Date().toISOString();
  const temporaryDirectory = mkdtempSync(join(tmpdir(), "herness-legal-"));
  try {
    const sqlPath = join(temporaryDirectory, "legal-documents.sql");
    writeFileSync(sqlPath, sqlFor(documents, createdAt), "utf8");
    console.log(`validated ${requiredLocales.length} locales × ${documentNames.length} documents = 60 records`);
    console.log(`version: ${version}`);
    console.log(`source: ${sourceDir || sourceUrl}`);
    if (!args.has("--remote")) {
      console.log(`dry run: SQL written to ${sqlPath}`);
      return;
    }

    for (const locale of requiredLocales) {
      for (const documentName of documentNames) {
        const item = documents[locale][documentName];
        const sourcePath = join(temporaryDirectory, `${locale}-${documentName}.md`);
        const r2Key = `legal/${appSlug}/${version}/${locale}/${documentName}.md`;
        writeFileSync(sourcePath, item.body, "utf8");
        runWrangler(["r2", "object", "put", `${bucket}/${r2Key}`, "--file", sourcePath, "--remote", "--content-type", "text/markdown; charset=utf-8"]);
      }
    }
    runWrangler(["d1", "execute", database, "--remote", "--file", sqlPath]);
    console.log("remote R2 upload and D1 upsert completed; run the readback script before publishing a release");
  } finally {
    rmSync(temporaryDirectory, { recursive: true, force: true });
  }
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : error);
  process.exitCode = 1;
});
