-- Marketplace listing metrics: real download and like counters plus the
-- admin-curated "Önerilenler" flag. Counters are denormalised onto the plugin
-- row so the public registry stays a single read per plugin.

ALTER TABLE marketplace_plugins ADD COLUMN downloads INTEGER NOT NULL DEFAULT 0;
ALTER TABLE marketplace_plugins ADD COLUMN likes INTEGER NOT NULL DEFAULT 0;
ALTER TABLE marketplace_plugins ADD COLUMN featured INTEGER NOT NULL DEFAULT 0;

CREATE TABLE IF NOT EXISTS marketplace_likes (
  plugin_id TEXT NOT NULL REFERENCES marketplace_plugins(id) ON DELETE CASCADE,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  PRIMARY KEY (plugin_id, user_id)
);
CREATE INDEX IF NOT EXISTS idx_marketplace_likes_user
  ON marketplace_likes(user_id);
