#!/usr/bin/env node
/**
 * Parse wrangler tail stdout for [http:slow], [http:trace], [d1:slow] lines.
 *
 * Usage:
 *   wrangler tail | node slow-log-parser.mjs --out reports/slow-log.json
 *   node slow-log-parser.mjs --summarize reports/slow-log.json
 *   node slow-log-parser.mjs --summarize reports/slow-log.json --md docs/performance-report.md
 */
import { createInterface } from "node:readline";
import { readFileSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { dirname, resolve } from "node:path";

const HTTP_RE =
  /\[http:(slow|trace)\]\s+(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)\s+(\S+)\s+(\d+)ms\s+(\d+)/;
const D1_RE = /\[d1:slow\]\s+(\d+)ms\s+(.+)/;

function parseArgs() {
  const args = process.argv.slice(2);
  const opts = { out: null, summarize: null, md: null, intervalMs: 5 * 60 * 1000 };
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--out") opts.out = args[++i];
    else if (args[i] === "--summarize") opts.summarize = args[++i];
    else if (args[i] === "--md") opts.md = args[++i];
    else if (args[i] === "--interval-ms") opts.intervalMs = Number(args[++i]);
  }
  return opts;
}

function p95(values) {
  if (!values.length) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  const idx = Math.ceil(sorted.length * 0.95) - 1;
  return sorted[Math.max(0, idx)];
}

function summarize(events) {
  const http = new Map();
  const d1 = new Map();

  for (const e of events) {
    if (e.type === "http") {
      const key = `${e.method} ${e.path}`;
      const bucket = http.get(key) || { key, method: e.method, path: e.path, ms: [] };
      bucket.ms.push(e.ms);
      http.set(key, bucket);
    } else if (e.type === "d1") {
      const key = e.sqlPreview;
      const bucket = d1.get(key) || { key, sqlPreview: e.sqlPreview, ms: [] };
      bucket.ms.push(e.ms);
      d1.set(key, bucket);
    }
  }

  const rank = (map) =>
    [...map.values()]
      .map((b) => ({
        ...b,
        count: b.ms.length,
        min: Math.min(...b.ms),
        max: Math.max(...b.ms),
        avg: Math.round(b.ms.reduce((a, c) => a + c, 0) / b.ms.length),
        p95: p95(b.ms),
      }))
      .sort((a, b) => b.p95 - a.p95);

  return {
    generatedAt: new Date().toISOString(),
    totalEvents: events.length,
    http: rank(http).slice(0, 20),
    d1: rank(d1).slice(0, 20),
  };
}

function toMarkdown(summary) {
  const lines = [
    "# Performance Report",
    "",
    `Generated: ${summary.generatedAt}`,
    `Total events: ${summary.totalEvents}`,
    "",
    "## Top HTTP endpoints (by p95)",
    "",
    "| Method | Path | Count | p95 (ms) | avg | max |",
    "|--------|------|-------|----------|-----|-----|",
  ];
  for (const r of summary.http.slice(0, 10)) {
    lines.push(`| ${r.method} | ${r.path} | ${r.count} | ${r.p95} | ${r.avg} | ${r.max} |`);
  }
  lines.push("", "## Top D1 queries (by p95)", "", "| SQL preview | Count | p95 (ms) |", "|-------------|-------|----------|");
  for (const r of summary.d1.slice(0, 10)) {
    lines.push(`| \`${r.sqlPreview}\` | ${r.count} | ${r.p95} |`);
  }
  lines.push("");
  return lines.join("\n");
}

function processLine(line, events) {
  const http = line.match(HTTP_RE);
  if (http) {
    events.push({
      type: "http",
      level: http[1],
      method: http[2],
      path: http[3],
      ms: Number(http[4]),
      status: Number(http[5]),
      at: new Date().toISOString(),
    });
    return;
  }
  const d1m = line.match(D1_RE);
  if (d1m) {
    events.push({
      type: "d1",
      ms: Number(d1m[1]),
      sqlPreview: d1m[2].trim(),
      at: new Date().toISOString(),
    });
  }
}

async function readStdin(events) {
  const rl = createInterface({ input: process.stdin, crlfDelay: Infinity });
  let lastFlush = Date.now();

  for await (const line of rl) {
    processLine(line, events);
    if (Date.now() - lastFlush >= parseArgs().intervalMs) {
      console.error(`[slow-log-parser] ${events.length} events collected…`);
      lastFlush = Date.now();
    }
  }
}

const opts = parseArgs();

if (opts.summarize) {
  const raw = JSON.parse(readFileSync(opts.summarize, "utf8"));
  const events = raw.events || raw;
  const summary = summarize(events);
  if (opts.md) {
    mkdirSync(dirname(resolve(opts.md)), { recursive: true });
    writeFileSync(opts.md, toMarkdown(summary));
    console.log(`Wrote ${opts.md}`);
  } else {
    console.log(JSON.stringify(summary, null, 2));
  }
  process.exit(0);
}

const events = [];
await readStdin(events);
const payload = { startedAt: new Date().toISOString(), events };
const summary = summarize(events);

if (opts.out) {
  const outPath = resolve(opts.out);
  mkdirSync(dirname(outPath), { recursive: true });
  writeFileSync(outPath, JSON.stringify(payload, null, 2));
  writeFileSync(outPath.replace(/\.json$/, ".summary.json"), JSON.stringify(summary, null, 2));
  console.error(`Wrote ${outPath} (${events.length} events)`);
} else {
  console.log(JSON.stringify(summary, null, 2));
}
