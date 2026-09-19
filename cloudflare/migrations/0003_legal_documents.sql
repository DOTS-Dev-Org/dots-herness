-- Versioned legal Markdown for mobile/web reads.  The body is duplicated in
-- D1 for query/readback and in R2 for immutable distribution artifacts.
CREATE TABLE IF NOT EXISTS legal_documents (
  app_slug TEXT NOT NULL,
  document_key TEXT NOT NULL CHECK (document_key IN ('terms', 'privacy_notice')),
  locale TEXT NOT NULL,
  version TEXT NOT NULL,
  body_markdown TEXT NOT NULL,
  sha256 TEXT NOT NULL CHECK (length(sha256) = 64),
  r2_key TEXT NOT NULL UNIQUE,
  translation_status TEXT NOT NULL CHECK (translation_status IN ('draft', 'approved', 'published')),
  source_locale TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  published_at TEXT,
  PRIMARY KEY (app_slug, document_key, locale, version)
);

CREATE INDEX IF NOT EXISTS idx_legal_documents_lookup
  ON legal_documents(app_slug, locale, version, document_key);

CREATE INDEX IF NOT EXISTS idx_legal_documents_status
  ON legal_documents(app_slug, locale, translation_status, published_at);
