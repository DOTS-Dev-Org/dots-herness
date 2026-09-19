# D1 schema reference — dotsherness-db

`0000_initial_schema.sql` contains the flattened identity/auth core of
`aiwatcher_web`; Marketplace tables are added by `0001_marketplace.sql` and
the immutable per-release license by `0002_marketplace_release_license.sql`.
Domain tables (AI provider tracking, usage windows, billing history, store
entitlements) were intentionally left out.

## Tables

| table | purpose |
|---|---|
| `users` | accounts. `email` unique NOCASE, `username` unique NOCASE (NOT NULL enforced by triggers), `role` in (user, admin, superadmin) |
| `workspaces` | tenant. `plan_slug` (free/pro/team, defs in `src/lib/plan_features.ts`), seat + subscription/gift columns |
| `workspace_members` | membership, `role` in (owner, admin, assistant, member); partial unique index = one owner per workspace |
| `refresh_tokens` | hashed refresh tokens (SHA-256), `token_hash` unique |
| `password_reset_tokens` | one active reset per user (unique on `user_id`) |
| `oauth_states` | OAuth code/PKCE state + native one-time handoff (`handoff_code_hash`) + legal-version columns |
| `qr_sessions` | cross-device QR login (`poll_secret_hash`, `short_code`) |
| `team_invites` | workspace invites, `token` unique |
| `user_devices` | device/session list |
| `user_fcm_tokens`, `user_notification_events` | push + in-app notification feed |
| `audit_events` | append-only audit log |
| `legal_consent_events` | append-only KVKK/consent evidence |
| `billing_orders` | order table kept; PayTR flow is a stub in this skeleton |
| `request_rate_limits` | D1-backed fixed-window rate limiter (replaces KV) |
| `provider_oauth_sessions`, `browser_scrape_sessions`, `usage_fetch_throttles` | short-lived transient state |
| `system_settings`, `landing_stats` | site config / public counters |
| `marketplace_plugins` | global native plugin identity, owner, visibility and verification status |
| `marketplace_releases` | immutable SemVer releases, IR/manifest metadata, source hash and license |
| `marketplace_artifacts` | per-platform/architecture R2 object, hash, signature and build status |

## Apply

```bash
npm run db:migrate:local     # local wrangler D1
npm run db:migrate:remote    # dotsherness-db on Cloudflare
```
