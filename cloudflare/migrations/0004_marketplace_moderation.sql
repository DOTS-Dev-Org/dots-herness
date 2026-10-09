-- Marketplace relevance, moderation, and community discovery boundaries.
-- Build/signature success is deliberately separate from publication approval.

ALTER TABLE marketplace_releases ADD COLUMN moderation_status TEXT NOT NULL DEFAULT 'pending_review';
ALTER TABLE marketplace_releases ADD COLUMN catalog_scope TEXT NOT NULL DEFAULT 'community';
ALTER TABLE marketplace_releases ADD COLUMN category TEXT NOT NULL DEFAULT 'other';
ALTER TABLE marketplace_releases ADD COLUMN category_confidence REAL NOT NULL DEFAULT 0;
ALTER TABLE marketplace_releases ADD COLUMN category_source TEXT NOT NULL DEFAULT 'legacy';
ALTER TABLE marketplace_releases ADD COLUMN risk_level TEXT NOT NULL DEFAULT 'unknown';
ALTER TABLE marketplace_releases ADD COLUMN risk_flags_json TEXT NOT NULL DEFAULT '[]';
ALTER TABLE marketplace_releases ADD COLUMN permission_manifest_json TEXT NOT NULL DEFAULT '[]';
ALTER TABLE marketplace_releases ADD COLUMN moderation_scores_json TEXT NOT NULL DEFAULT '{}';
ALTER TABLE marketplace_releases ADD COLUMN moderation_reason TEXT NOT NULL DEFAULT '';
ALTER TABLE marketplace_releases ADD COLUMN moderation_model TEXT;
ALTER TABLE marketplace_releases ADD COLUMN ai_reviewed_at TEXT;
ALTER TABLE marketplace_releases ADD COLUMN reviewed_by TEXT;
ALTER TABLE marketplace_releases ADD COLUMN reviewed_at TEXT;
ALTER TABLE marketplace_releases ADD COLUMN review_notes TEXT;

CREATE INDEX IF NOT EXISTS idx_marketplace_releases_moderation
  ON marketplace_releases(moderation_status, catalog_scope, category, created_at DESC);

CREATE TABLE IF NOT EXISTS marketplace_reports (
  id TEXT PRIMARY KEY,
  plugin_id TEXT NOT NULL REFERENCES marketplace_plugins(id) ON DELETE CASCADE,
  release_id TEXT NOT NULL REFERENCES marketplace_releases(id) ON DELETE CASCADE,
  reporter_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  reason TEXT NOT NULL
    CHECK (reason IN ('malware', 'credential_theft', 'data_exfiltration', 'deceptive_listing', 'spam', 'copyright', 'other')),
  details TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'in_review', 'resolved', 'dismissed')),
  resolution_notes TEXT,
  resolved_by TEXT REFERENCES users(id) ON DELETE RESTRICT,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  resolved_at TEXT,
  UNIQUE(release_id, reporter_user_id, reason)
);

CREATE INDEX IF NOT EXISTS idx_marketplace_reports_status
  ON marketplace_reports(status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_marketplace_reports_release
  ON marketplace_reports(release_id, created_at DESC);
