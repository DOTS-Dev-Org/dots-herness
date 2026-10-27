-- ── refresh token rotation ────────────────────────────────────────────────
-- A refresh token is single-use: each refresh marks the current row as
-- rotated and issues a new one. Presenting a token that was already rotated
-- (outside the short grace window that covers a worker restart) means the
-- token was copied, so every session of that account is revoked.
ALTER TABLE refresh_tokens ADD COLUMN rotated_at TEXT;
ALTER TABLE refresh_tokens ADD COLUMN revoked_at TEXT;
CREATE INDEX IF NOT EXISTS idx_refresh_tokens_rotated ON refresh_tokens(rotated_at);
