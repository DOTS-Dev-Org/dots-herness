-- DOTS Herness unified backend — consolidated auth/identity/workspace schema.
-- This is the post-migration shape of aiwatcher_web's identity core, flattened
-- into one file. Domain tables (providers, usage, billing history, store
-- entitlements) are intentionally omitted; add them per-feature as needed.

PRAGMA foreign_keys = ON;

-- Plan definitions live in code (src/lib/plan_features.ts PLAN_DEFS), not the DB.

-- ── users ────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS users (
  id TEXT PRIMARY KEY,
  email TEXT NOT NULL UNIQUE COLLATE NOCASE,
  password_hash TEXT NOT NULL,
  role TEXT NOT NULL DEFAULT 'user' CHECK (role IN ('user', 'superadmin', 'admin')),
  email_verified INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now')),
  name TEXT DEFAULT '',
  surname TEXT DEFAULT '',
  auth_provider TEXT DEFAULT 'email',
  provider_id TEXT DEFAULT '',
  avatar TEXT DEFAULT '',
  plan TEXT DEFAULT 'free',
  status TEXT DEFAULT 'active',
  notifications_enabled INTEGER DEFAULT 1,
  phone TEXT NOT NULL DEFAULT '',
  address TEXT NOT NULL DEFAULT '',
  username TEXT
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_users_username_unique
  ON users (username COLLATE NOCASE)
  WHERE username IS NOT NULL AND TRIM(username) != '';

CREATE TRIGGER IF NOT EXISTS users_username_not_null_insert
BEFORE INSERT ON users
WHEN NEW.username IS NULL OR TRIM(NEW.username) = ''
BEGIN
  SELECT RAISE(ABORT, 'username cannot be null or empty');
END;

CREATE TRIGGER IF NOT EXISTS users_username_not_null_update
BEFORE UPDATE OF username ON users
WHEN NEW.username IS NULL OR TRIM(NEW.username) = ''
BEGIN
  SELECT RAISE(ABORT, 'username cannot be null or empty');
END;

-- ── workspaces + members ─────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS workspaces (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  plan_slug TEXT NOT NULL DEFAULT 'free',
  billing_cycle TEXT CHECK (billing_cycle IN ('monthly', 'yearly')),
  extra_seats INTEGER NOT NULL DEFAULT 0,
  store_extra_seats INTEGER NOT NULL DEFAULT 0,
  subscription_started_at TEXT,
  subscription_ends_at TEXT,
  gift_months INTEGER,
  gift_started_at TEXT,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS workspace_members (
  workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role TEXT NOT NULL DEFAULT 'owner' CHECK (role IN ('owner', 'admin', 'assistant', 'member')),
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  joined_at TEXT,
  note TEXT,
  PRIMARY KEY (workspace_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_workspace_members_user ON workspace_members(user_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_workspace_members_single_owner
  ON workspace_members(workspace_id)
  WHERE role = 'owner';

-- ── auth tokens ──────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS refresh_tokens (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token_hash TEXT NOT NULL UNIQUE,
  expires_at TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_refresh_tokens_user ON refresh_tokens(user_id);

CREATE TABLE IF NOT EXISTS password_reset_tokens (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token_hash TEXT NOT NULL UNIQUE,
  expires_at TEXT NOT NULL,
  used_at TEXT,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_password_reset_tokens_user_id
  ON password_reset_tokens(user_id);

-- ── OAuth state + native PKCE handoff (one table, post-0095 shape) ────────
CREATE TABLE IF NOT EXISTS oauth_states (
  state TEXT PRIMARY KEY,
  user_id TEXT,
  provider TEXT,
  redirect_uri TEXT,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  expires_at TEXT,
  client TEXT DEFAULT 'web',
  terms_version TEXT,
  privacy_notice_version TEXT,
  explicit_consent_version TEXT,
  explicit_consent_granted INTEGER NOT NULL DEFAULT 0,
  accepted_locale TEXT,
  pkce_challenge TEXT,
  client_state TEXT,
  handoff_code_hash TEXT,
  handoff_expires_at TEXT,
  consumed_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_oauth_states_handoff_code_hash
  ON oauth_states(handoff_code_hash)
  WHERE handoff_code_hash IS NOT NULL;

-- ── QR cross-device login ────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS qr_sessions (
  id TEXT PRIMARY KEY,
  user_id TEXT REFERENCES users(id),
  status TEXT NOT NULL DEFAULT 'pending',
  expires_at TEXT NOT NULL,
  confirmed_at TEXT,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  poll_secret_hash TEXT,
  short_code TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_qr_sessions_short_code ON qr_sessions(short_code);

-- ── team invites ─────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS team_invites (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  email TEXT NOT NULL,
  role TEXT NOT NULL DEFAULT 'member',
  token TEXT NOT NULL UNIQUE,
  invited_by TEXT REFERENCES users(id),
  expires_at TEXT NOT NULL,
  accepted_at TEXT,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_team_invites_email ON team_invites(email);
CREATE INDEX IF NOT EXISTS idx_team_invites_workspace_id ON team_invites(workspace_id);

-- ── devices ──────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS user_devices (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  device_name TEXT NOT NULL,
  os TEXT NOT NULL,
  browser TEXT NOT NULL,
  ip TEXT,
  last_active TEXT NOT NULL,
  current_session INTEGER DEFAULT 0,
  device_fingerprint TEXT,
  app_version TEXT DEFAULT '',
  platform TEXT DEFAULT 'web',
  country TEXT DEFAULT '',
  city TEXT DEFAULT '',
  created_at TEXT
);

-- ── push notifications ───────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS user_fcm_tokens (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token TEXT NOT NULL,
  platform TEXT NOT NULL CHECK (platform IN ('ios', 'android', 'web', 'desktop')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now')),
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  UNIQUE(user_id, token)
);
CREATE INDEX IF NOT EXISTS idx_user_fcm_tokens_user ON user_fcm_tokens(user_id);

CREATE TABLE IF NOT EXISTS user_notification_events (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  workspace_id TEXT NOT NULL,
  type TEXT NOT NULL,
  title TEXT NOT NULL,
  body TEXT NOT NULL,
  provider_id TEXT,
  payload TEXT,
  created_at TEXT NOT NULL,
  delivered_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_user_notification_events_poll
  ON user_notification_events(user_id, workspace_id, created_at);

-- ── audit ────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS audit_events (
  id TEXT PRIMARY KEY,
  workspace_id TEXT,
  actor_user_id TEXT NOT NULL,
  actor_email TEXT,
  action TEXT NOT NULL,
  entity_type TEXT NOT NULL,
  entity_id TEXT,
  metadata_json TEXT,
  ip TEXT,
  user_agent TEXT,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_audit_workspace_time ON audit_events (workspace_id, created_at);
CREATE INDEX IF NOT EXISTS idx_audit_actor_time ON audit_events (actor_user_id, created_at);
CREATE INDEX IF NOT EXISTS idx_audit_entity ON audit_events (entity_type, entity_id);

-- ── legal consent (append-only) ──────────────────────────────────────────
CREATE TABLE IF NOT EXISTS legal_consent_events (
  id TEXT PRIMARY KEY,
  user_id TEXT REFERENCES users(id) ON DELETE SET NULL,
  anonymous_id TEXT,
  purpose TEXT NOT NULL,
  action TEXT NOT NULL CHECK (action IN ('accepted', 'acknowledged', 'granted', 'denied', 'withdrawn')),
  document_key TEXT NOT NULL,
  document_version TEXT NOT NULL,
  locale TEXT NOT NULL DEFAULT 'tr',
  source TEXT NOT NULL DEFAULT 'web',
  ip TEXT,
  user_agent TEXT,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_legal_consent_user_created
  ON legal_consent_events(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_legal_consent_anonymous_created
  ON legal_consent_events(anonymous_id, created_at DESC);

-- ── billing orders (table kept; PayTR flow is a stub in this skeleton) ────
CREATE TABLE IF NOT EXISTS billing_orders (
  id TEXT PRIMARY KEY,
  merchant_oid TEXT NOT NULL UNIQUE,
  plan_slug TEXT NOT NULL,
  customer_email TEXT NOT NULL,
  customer_name TEXT NOT NULL DEFAULT '',
  customer_phone TEXT NOT NULL DEFAULT '',
  amount_minor INTEGER NOT NULL,
  currency TEXT NOT NULL DEFAULT 'TL',
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'completed', 'failed', 'cancelled')),
  user_id TEXT REFERENCES users(id),
  workspace_id TEXT REFERENCES workspaces(id),
  metadata_json TEXT,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now')),
  completed_at TEXT,
  from_plan_slug TEXT,
  proration_credit_minor INTEGER DEFAULT 0,
  proration_currency TEXT DEFAULT 'TL',
  cycle_started_at TEXT,
  kind TEXT DEFAULT 'new',
  paytr_token TEXT,
  terms_version TEXT,
  precontract_version TEXT,
  distance_sales_version TEXT,
  subscription_version TEXT,
  accepted_locale TEXT
);

-- ── D1-backed transient state (replaces Cloudflare KV) ───────────────────
CREATE TABLE IF NOT EXISTS request_rate_limits (
  rate_key TEXT PRIMARY KEY,
  window_bucket INTEGER NOT NULL,
  hit_count INTEGER NOT NULL DEFAULT 0,
  expires_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_request_rate_limits_expires
  ON request_rate_limits(expires_at);

CREATE TABLE IF NOT EXISTS provider_oauth_sessions (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  workspace_id TEXT,
  provider TEXT NOT NULL,
  started_at TEXT NOT NULL,
  expires_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_provider_oauth_sessions_user_provider
  ON provider_oauth_sessions(user_id, provider, started_at DESC);

CREATE TABLE IF NOT EXISTS browser_scrape_sessions (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  provider TEXT NOT NULL,
  created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  logged_in INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_browser_scrape_sessions_expires
  ON browser_scrape_sessions(expires_at);

CREATE TABLE IF NOT EXISTS usage_fetch_throttles (
  throttle_key TEXT PRIMARY KEY,
  expires_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_usage_fetch_throttles_expires
  ON usage_fetch_throttles(expires_at);

-- ── site settings ────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS system_settings (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS landing_stats (
  stat_key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  sort_order INTEGER NOT NULL,
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

-- ── seeds ────────────────────────────────────────────────────────────────
INSERT OR IGNORE INTO system_settings (key, value) VALUES
  ('github_link', 'https://github.com/DOTS-Group/herness'),
  ('registration_open', 'true');
