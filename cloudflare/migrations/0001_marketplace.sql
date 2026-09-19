-- Native plugin marketplace. Releases are immutable; ownership is attached to
-- the first user that reserves a global plugin id.

CREATE TABLE IF NOT EXISTS marketplace_plugins (
  id TEXT PRIMARY KEY,
  owner_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  name TEXT NOT NULL,
  description TEXT NOT NULL DEFAULT '',
  author TEXT NOT NULL DEFAULT '',
  homepage TEXT,
  license TEXT NOT NULL,
  verification_status TEXT NOT NULL DEFAULT 'unverified'
    CHECK (verification_status IN ('unverified', 'verified')),
  source_visibility TEXT NOT NULL DEFAULT 'public'
    CHECK (source_visibility IN ('public', 'private')),
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now')),
  unpublished_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_marketplace_plugins_owner
  ON marketplace_plugins(owner_user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_marketplace_plugins_visible
  ON marketplace_plugins(unpublished_at, updated_at DESC);

CREATE TABLE IF NOT EXISTS marketplace_releases (
  id TEXT PRIMARY KEY,
  plugin_id TEXT NOT NULL REFERENCES marketplace_plugins(id) ON DELETE CASCADE,
  version TEXT NOT NULL,
  -- Added as a nullable-compatible column in 0002 for already-created DBs.
  -- New writes always provide the release license.
  manifest_json TEXT NOT NULL DEFAULT '{}',
  ir_json TEXT NOT NULL,
  source_object_key TEXT,
  source_sha256 TEXT,
  status TEXT NOT NULL DEFAULT 'draft'
    CHECK (status IN ('draft', 'published', 'unpublished')),
  created_by TEXT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  published_at TEXT,
  UNIQUE(plugin_id, version)
);
CREATE INDEX IF NOT EXISTS idx_marketplace_releases_plugin
  ON marketplace_releases(plugin_id, created_at DESC);

CREATE TABLE IF NOT EXISTS marketplace_artifacts (
  release_id TEXT NOT NULL REFERENCES marketplace_releases(id) ON DELETE CASCADE,
  platform TEXT NOT NULL CHECK (platform IN ('macos', 'windows', 'linux')),
  architecture TEXT NOT NULL,
  object_key TEXT,
  sha256 TEXT,
  size INTEGER NOT NULL DEFAULT 0,
  signature_json TEXT,
  build_status TEXT NOT NULL DEFAULT 'pending'
    CHECK (build_status IN ('pending', 'ready', 'failed')),
  build_error TEXT,
  built_at TEXT,
  PRIMARY KEY (release_id, platform, architecture)
);
CREATE INDEX IF NOT EXISTS idx_marketplace_artifacts_release_status
  ON marketplace_artifacts(release_id, build_status);
