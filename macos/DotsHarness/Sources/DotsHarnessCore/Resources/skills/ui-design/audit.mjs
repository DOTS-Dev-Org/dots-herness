#!/usr/bin/env node
// UI audit. No dependencies.
//
//   node audit.mjs --static <dir>    static defects + manifest drift
//   node audit.mjs --snippet         print the in-page snippet to paste
//                                    into the live page at each viewport
//
// Exits 1 when any defect is found, so it can gate a commit.

import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, extname } from "node:path";

const SRC = /\.(css|scss|html|jsx|tsx|vue|svelte)$/;
const SKIP = /^(node_modules|\.git|dist|build|\.next|out|vendor|Pods)$/;

function walk(dir, out = []) {
  for (const name of readdirSync(dir)) {
    if (SKIP.test(name)) continue;
    const path = join(dir, name);
    if (statSync(path).isDirectory()) walk(path, out);
    else if (SRC.test(extname(path)) || name.endsWith(".intent.yaml")) out.push(path);
  }
  return out;
}

// A raw length is allowed for hairlines, zero, and full-bleed sizes.
const ALLOWED_LENGTH = /^(0|1px|100%|100vh|100vw|999px)$/;
const LENGTH_PROP = /\b(padding|margin|gap|font-size|border-radius|inset|top|right|bottom|left|width|height|min-[\w-]+|max-[\w-]+)\s*:\s*([^;{}]+)/gi;
const LAYOUT_PROP = /\b(display|grid-template|flex-direction|grid-auto|place-|justify-|align-)/;

const defects = [];
const add = (file, line, rule, message) => defects.push({ file, line, rule, message });

function auditFile(file, text) {
  const lines = text.split("\n");

  lines.forEach((line, i) => {
    const n = i + 1;

    // Raw lengths outside the token system.
    for (const m of line.matchAll(LENGTH_PROP)) {
      const value = m[2].trim();
      if (/var\(|calc\(|clamp\(/.test(value)) continue;
      for (const token of value.split(/\s+/)) {
        if (!/\d/.test(token) || ALLOWED_LENGTH.test(token)) continue;
        if (/^\d+(\.\d+)?(px|rem|em)$/.test(token))
          add(file, n, "hardcoded-length", `${m[1]}: ${token} — use a token from tokens.css`);
      }
    }

    // Dead controls.
    if (/on(Click|Press|Change|Submit)\s*=\s*\{?\s*\(\s*\)\s*=>\s*\{\s*\}/.test(line))
      add(file, n, "dead-handler", "empty handler — wire it or remove the control");
    if (/href\s*=\s*["'](#["']|javascript:void)/.test(line))
      add(file, n, "dead-link", 'href="#" is not a destination');
    if (/(TODO|FIXME|not implemented)/i.test(line) && /on(Click|Press|Submit)|action=/.test(line))
      add(file, n, "unimplemented-control", "control marked unfinished");

    // A media query must not make a component layout decision.
    if (/@media/.test(line) && !/(pointer|prefers-|orientation|print)/.test(line)) {
      if (LAYOUT_PROP.test(lines.slice(i, i + 20).join("\n")))
        add(file, n, "media-layout", "component layout in @media — use @container");
    }
  });

  // Clickable but not a control.
  for (const m of text.matchAll(/<(div|span)([^>]*onClick[^>]*)>/g)) {
    const line = text.slice(0, m.index).split("\n").length;
    if (!/role=/.test(m[2])) add(file, line, "unlabelled-control", `clickable <${m[1]}> with no role — use a button`);
  }
}

function auditManifests(files) {
  const source = files.filter((f) => !f.endsWith(".intent.yaml"));
  const sourceText = new Map(source.map((f) => [f, readFileSync(f, "utf8")]));
  const declared = new Map();
  const rendered = new Map();

  for (const file of files) {
    if (!file.endsWith(".intent.yaml")) {
      for (const m of sourceText.get(file).matchAll(/data-intent\s*=\s*["']([\w-]+)["']/g)) rendered.set(m[1], file);
      continue;
    }
    const text = readFileSync(file, "utf8");
    for (const m of text.matchAll(/^\s*-\s*id:\s*["']?([\w-]+)/gm)) declared.set(m[1], file);
    for (const m of text.matchAll(/^\s*action:\s*["']?([\w./:-]+)/gm)) {
      const action = m[1];
      if (action.startsWith("route:")) continue;
      const symbol = new RegExp(`\\b${action}\\b`);
      if (![...sourceText.values()].some((t) => symbol.test(t)))
        add(file, 0, "missing-action", `action "${action}" resolves to nothing in the source`);
    }
  }

  for (const [id, file] of rendered)
    if (!declared.has(id)) add(file, 0, "undeclared-control", `data-intent="${id}" has no manifest entry`);
  for (const [id, file] of declared)
    if (!rendered.has(id)) add(file, 0, "unrendered-intent", `manifest declares "${id}" but nothing renders it`);
}

const SNIPPET = String.raw`(() => {
  const problems = [];
  const name = (el) => el.tagName.toLowerCase() + (el.id ? "#" + el.id : "") +
    (typeof el.className === "string" && el.className.trim() ? "." + el.className.trim().split(/\s+/)[0] : "");
  const push = (rule, el, note) => problems.push({ rule, el: name(el), note });

  const lum = (c) => {
    const [r, g, b] = (c.match(/[\d.]+/g) || [0, 0, 0]).slice(0, 3).map(Number).map((v) => {
      v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
    });
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
  };
  const ratio = (a, b) => { const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p); return (x + 0.05) / (y + 0.05); };
  const bgOf = (el) => {
    for (let n = el; n; n = n.parentElement) {
      const bg = getComputedStyle(n).backgroundColor;
      if (bg && !/rgba?\([^)]*,\s*0\)/.test(bg)) return bg;
    }
    return "rgb(255, 255, 255)";
  };

  const doc = document.documentElement;
  if (doc.scrollWidth > doc.clientWidth + 1)
    problems.push({ rule: "page-overflow", el: "html", note: doc.scrollWidth + " > " + doc.clientWidth });

  const tapMin = matchMedia("(pointer: coarse)").matches ? 44 : 32;

  for (const el of document.querySelectorAll("body *")) {
    const style = getComputedStyle(el);
    if (style.display === "none" || style.visibility === "hidden") continue;
    const rect = el.getBoundingClientRect();
    if (!rect.width || !rect.height) continue;

    if (el.scrollWidth > el.clientWidth + 1 && style.overflowX === "visible")
      push("overflow", el, el.scrollWidth + "px inside " + el.clientWidth + "px");
    if (el.scrollHeight > el.clientHeight + 1 && style.overflowY === "hidden")
      push("clipped-text", el, "content taller than its box");

    if (el.matches("a,button,input,select,textarea,[role=button],[role=link],[tabindex]:not([tabindex='-1'])")) {
      if (rect.width < tapMin || rect.height < tapMin)
        push("tap-target", el, Math.round(rect.width) + "x" + Math.round(rect.height) + " < " + tapMin);
      if (!(el.getAttribute("aria-label") || el.textContent || el.getAttribute("title") || "").trim() && !el.matches("input,select,textarea"))
        push("no-accessible-name", el, "nothing announces this control");
      const wired = el.hasAttribute("data-intent") ||
        (el.getAttribute("href") || "").replace(/^#$/, "") ||
        (el.form && (el.type === "submit" || el.matches("input,select,textarea")));
      if (!wired && !el.disabled) push("possibly-dead", el, "no data-intent, no destination, no form");
    }

    if (el.children.length === 0 && el.textContent.trim()) {
      const r = ratio(style.color, bgOf(el));
      const size = parseFloat(style.fontSize);
      const large = size >= 24 || (size >= 18.66 && Number(style.fontWeight) >= 700);
      if (r < (large ? 3 : 4.5)) push("contrast", el, r.toFixed(2) + ":1");
    }
  }

  const radii = new Set([...document.querySelectorAll("body *")]
    .map((el) => getComputedStyle(el).borderTopLeftRadius).filter((r) => r !== "0px"));
  if (radii.size === 1)
    problems.push({ rule: "uniform-radius", el: "document", note: "every radius is " + [...radii][0] + " — nesting law not applied" });

  return { viewport: innerWidth + "x" + innerHeight, count: problems.length, problems };
})()`;

const [, , mode, target] = process.argv;

if (mode === "--snippet") {
  console.log(SNIPPET);
  process.exit(0);
}

if (mode !== "--static" || !target) {
  console.error("usage: node audit.mjs --static <dir> | node audit.mjs --snippet");
  process.exit(2);
}

const files = walk(target);
for (const file of files) {
  if (!file.endsWith(".intent.yaml")) auditFile(file, readFileSync(file, "utf8"));
}
auditManifests(files);

if (!defects.length) {
  console.log(`clean — ${files.length} files checked`);
  process.exit(0);
}

const byRule = {};
for (const d of defects) (byRule[d.rule] ??= []).push(d);
for (const [rule, list] of Object.entries(byRule).sort((a, b) => b[1].length - a[1].length)) {
  console.log(`\n${rule} (${list.length})`);
  for (const d of list.slice(0, 20)) console.log(`  ${d.file}:${d.line}  ${d.message}`);
  if (list.length > 20) console.log(`  ... ${list.length - 20} more`);
}
console.log(`\n${defects.length} defects in ${files.length} files`);
process.exit(1);
