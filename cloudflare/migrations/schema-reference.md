# D1 schema reference — dotsherness-db

`0000_initial_schema.sql` contains the flattened identity/auth core of
`aiwatcher_web`; Marketplace tables are added by `0001_marketplace.sql`, the
immutable per-release license by `0002_marketplace_release_license.sql`, and
the AI moderation/community boundary by `0004_marketplace_moderation.sql`.
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
| `marketplace_releases` | immutable SemVer releases, IR/manifest metadata, source hash, license, AI classification and review state |
| `marketplace_artifacts` | per-platform/architecture R2 object, hash, signature and build status |
| `marketplace_reports` | user abuse reports and admin resolution/takedown state |
| `marketplace_likes` | one row per user like; `marketplace_plugins.likes/downloads/featured` (0006) carry the listing counters and the curated flag |
| `marketplace_catalog_items` | skills and project starters (0007): listing payload plus downloads/likes/featured; `marketplace_catalog_likes` holds one row per user like |
| `media_community_posts`, `media_community_likes` | canvases shared from the Media studio (hidden until an admin approves) and their per-user likes |

## Apply

```bash
npm run db:migrate:local     # local wrangler D1
npm run db:migrate:remote    # dotsherness-db on Cloudflare
```
