---
name: app-store-preflight-compliance
description: Run the Greenlight iOS and Android store preflight gate for HerNess and triage release blockers.
---

# HerNess store gate

Run the repository wrapper from the project root:

```sh
tools/store-gate.sh .
```

The wrapper runs `greenlight preflight . --format json --exit-code`. Greenlight scans both mobile projects in one pass. Fix findings in this order: `CRITICAL`, `HIGH`, `WARN`, then `INFO`. Re-run after each safe fix and stop after three correction passes. A missing CLI is a failed gate, not a pass.

Use the active permission mode consistently:

- `ask`: prepare a diff and wait for approval.
- `approve me`: present each correction for approval.
- `full access`: apply safe source/config corrections automatically.

Never infer Apple or Google account access, signing, privacy-policy publication, store agreements, purchases, or submission success from a static scan. Runtime verification is optional and must not receive production credentials from this repository.
