-- Media community: canvases users share from the Media studio.
-- A post stays hidden until an admin approves it.

CREATE TABLE IF NOT EXISTS media_community_posts (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  category TEXT NOT NULL CHECK (category IN ('social', 'uiux', 'presentation', 'other')),
  canvas_json TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending_review'
    CHECK (status IN ('pending_review', 'approved', 'rejected')),
  likes INTEGER NOT NULL DEFAULT 0,
  reviewed_by TEXT REFERENCES users(id) ON DELETE SET NULL,
  reviewed_at TEXT,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_media_community_posts_feed
  ON media_community_posts(status, likes DESC, created_at DESC);

CREATE TABLE IF NOT EXISTS media_community_likes (
  post_id TEXT NOT NULL REFERENCES media_community_posts(id) ON DELETE CASCADE,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  PRIMARY KEY (post_id, user_id)
);
