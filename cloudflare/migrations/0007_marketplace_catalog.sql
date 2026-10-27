-- Skills and project starters join the plugin catalog: served from D1 with the
-- same real download/like counters and the admin-curated "Önerilenler" flag.
-- `payload_json` is the listing as clients decode it; counters live in columns
-- so a payload edit can never reset them.

CREATE TABLE IF NOT EXISTS marketplace_catalog_items (
  kind TEXT NOT NULL CHECK (kind IN ('skill', 'starter')),
  id TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  sort_order INTEGER NOT NULL DEFAULT 0,
  downloads INTEGER NOT NULL DEFAULT 0,
  likes INTEGER NOT NULL DEFAULT 0,
  featured INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now')),
  PRIMARY KEY (kind, id)
);

CREATE TABLE IF NOT EXISTS marketplace_catalog_likes (
  kind TEXT NOT NULL,
  item_id TEXT NOT NULL,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  PRIMARY KEY (kind, item_id, user_id),
  FOREIGN KEY (kind, item_id) REFERENCES marketplace_catalog_items(kind, id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_marketplace_catalog_likes_user
  ON marketplace_catalog_likes(user_id);

-- The listings the apps shipped with, moved here so they are edited on the
-- server from now on. Counters start at zero: nothing is invented.

INSERT OR IGNORE INTO marketplace_catalog_items (kind, id, payload_json, sort_order, featured) VALUES ('skill', 'frontend-design', '{"id": "frontend-design", "name": "Frontend Design", "description": "Guidance for distinctive, intentional visual design when building new UI or reshaping an existing one.", "githubURL": "https://github.com/anthropics/skills", "skillURL": "https://github.com/anthropics/skills/blob/main/skills/frontend-design/SKILL.md", "downloadURL": "https://raw.githubusercontent.com/anthropics/skills/main/skills/frontend-design/SKILL.md", "revision": "main", "sha256": null, "snapshotDate": "2026-08-28", "category": "design", "publisher": "Anthropic", "publisherBadge": "official"}', 0, 1);
INSERT OR IGNORE INTO marketplace_catalog_items (kind, id, payload_json, sort_order, featured) VALUES ('skill', 'skill-creator', '{"id": "skill-creator", "name": "Skill Creator", "description": "Create, modify, improve, and evaluate reusable agent skills with focused instructions and validation.", "githubURL": "https://github.com/anthropics/skills", "skillURL": "https://github.com/anthropics/skills/blob/main/skills/skill-creator/SKILL.md", "downloadURL": "https://raw.githubusercontent.com/anthropics/skills/main/skills/skill-creator/SKILL.md", "revision": "main", "sha256": null, "snapshotDate": "2026-08-28", "category": "authoring", "publisher": "Anthropic", "publisherBadge": "official"}', 1, 1);
INSERT OR IGNORE INTO marketplace_catalog_items (kind, id, payload_json, sort_order, featured) VALUES ('skill', 'vercel-react-best-practices', '{"id": "vercel-react-best-practices", "name": "Vercel React Best Practices", "description": "Performance guidance for React and Next.js code, including data fetching, rendering, and bundle optimization.", "githubURL": "https://github.com/vercel-labs/agent-skills", "skillURL": "https://github.com/vercel-labs/agent-skills/blob/main/skills/react-best-practices/SKILL.md", "downloadURL": "https://raw.githubusercontent.com/vercel-labs/agent-skills/main/skills/react-best-practices/SKILL.md", "revision": "main", "sha256": null, "snapshotDate": "2026-08-28", "category": "coding", "publisher": "Vercel Labs"}', 2, 1);
INSERT OR IGNORE INTO marketplace_catalog_items (kind, id, payload_json, sort_order, featured) VALUES ('skill', 'ppt-generation', '{"id": "ppt-generation", "name": "PPT Generation", "description": "Create visually rich PowerPoint presentations by composing slide content and visual assets.", "githubURL": "https://github.com/bytedance/deer-flow", "skillURL": "https://github.com/bytedance/deer-flow/blob/main/skills/public/ppt-generation/SKILL.md", "downloadURL": "https://raw.githubusercontent.com/bytedance/deer-flow/main/skills/public/ppt-generation/SKILL.md", "revision": "main", "sha256": null, "snapshotDate": "2026-08-28", "category": "documents", "publisher": "ByteDance"}', 3, 0);
INSERT OR IGNORE INTO marketplace_catalog_items (kind, id, payload_json, sort_order, featured) VALUES ('starter', 'web', '{"id": "web", "systemImage": "globe", "category": "web", "title": "Web app", "detail": "Next.js with TypeScript, a layout, an example API route and linting.", "prompt": "Scaffold a Next.js (App Router, TypeScript) web app in this empty folder: a home page, a shared layout, one example API route, ESLint, and a README with run commands. Install dependencies and confirm it builds."}', 0, 0);
INSERT OR IGNORE INTO marketplace_catalog_items (kind, id, payload_json, sort_order, featured) VALUES ('starter', 'landing', '{"id": "landing", "systemImage": "doc.richtext", "category": "web", "title": "Landing page", "detail": "Static HTML and CSS with hero, features, pricing and contact. No build step.", "prompt": "Scaffold a static landing page in this empty folder with plain HTML, CSS and a little JavaScript, no build step: hero, features, pricing and contact sections, responsive down to phone width. Add a README on how to preview it."}', 1, 0);
INSERT OR IGNORE INTO marketplace_catalog_items (kind, id, payload_json, sort_order, featured) VALUES ('starter', 'api', '{"id": "api", "systemImage": "server.rack", "category": "backend", "title": "API service", "detail": "FastAPI with a health check, an example resource, settings and tests.", "prompt": "Scaffold a FastAPI service in this empty folder: a health endpoint, one example CRUD resource with Pydantic models, settings from environment variables, pytest tests, and a README with run commands. Verify the tests pass."}', 2, 0);
INSERT OR IGNORE INTO marketplace_catalog_items (kind, id, payload_json, sort_order, featured) VALUES ('starter', 'ios', '{"id": "ios", "systemImage": "iphone", "category": "mobile", "title": "iOS app", "detail": "SwiftUI with two screens, an observable model and a unit test.", "prompt": "Scaffold a SwiftUI iOS app in this empty folder as a Swift package plus an XcodeGen project.yml: a tab view with two example screens, an observable model, and one unit test. Add a README on how to generate and run the project."}', 3, 0);
INSERT OR IGNORE INTO marketplace_catalog_items (kind, id, payload_json, sort_order, featured) VALUES ('starter', 'worker', '{"id": "worker", "systemImage": "cloud", "category": "backend", "title": "Cloudflare Worker", "detail": "TypeScript API on Workers with typed bindings and a test.", "prompt": "Scaffold a Cloudflare Worker (TypeScript) in this empty folder with wrangler: a JSON API with two routes, typed environment bindings, a vitest test, and a README covering local dev and deploy."}', 4, 0);
INSERT OR IGNORE INTO marketplace_catalog_items (kind, id, payload_json, sort_order, featured) VALUES ('starter', 'cli', '{"id": "cli", "systemImage": "terminal", "category": "tools", "title": "Command-line tool", "detail": "Python package with subcommands, tests and install instructions.", "prompt": "Scaffold a Python command-line tool in this empty folder with a pyproject.toml: an argparse entry point with two subcommands, a tests folder with pytest, and a README with install and usage. Verify the tests pass."}', 5, 0);
