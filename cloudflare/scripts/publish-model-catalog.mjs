// Copyright (c) 2026 DOTS
// Publishes the model lists from the app's providers.json to R2 so installed
// apps pick up new models without a release. Only models and the client
// user-agent are published; the app ignores everything else from the remote.
//
// usage: node cloudflare/scripts/publish-model-catalog.mjs [--dry-run]

import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const repositoryRoot = join(dirname(fileURLToPath(import.meta.url)), "../..");
const source = join(repositoryRoot, "macos/DotsHarness/Sources/DotsHarnessCore/Resources/providers.json");
const wrangler = process.env.HERNESS_WRANGLER_BIN || "wr-dotsherness";

const catalog = JSON.parse(readFileSync(source, "utf8"))
  .filter((provider) => provider.models?.length)
  .map((provider) => ({
    id: provider.id,
    models: provider.models,
    userAgent: provider.transport?.extraHeaders?.["user-agent"],
  }));

const file = join(mkdtempSync(join(tmpdir(), "model-catalog-")), "models.json");
writeFileSync(file, JSON.stringify(catalog));
console.log(`${catalog.length} providers, ${catalog.reduce((n, p) => n + p.models.length, 0)} models -> ${file}`);
if (process.argv.includes("--dry-run")) process.exit(0);

// The project alias is a shell wrapper on some developer machines, hence zsh -ic.
execFileSync("zsh", ["-ic", `${wrangler} r2 object put dotsherness-assets/catalog/models.json --file '${file}' --content-type application/json --remote`], {
  cwd: join(repositoryRoot, "cloudflare"),
  stdio: "inherit",
});
