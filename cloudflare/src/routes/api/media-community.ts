import { Hono } from "hono";
import type { Env, AppVariables } from "../../env";
import { requireAuth } from "../../middleware/auth";

const mediaCommunityApi = new Hono<{ Bindings: Env; Variables: AppVariables }>();
const mediaCommunityPublic = new Hono<{ Bindings: Env; Variables: AppVariables }>();

// Keep the public URL compatible with older clients while community sharing is paused.
mediaCommunityPublic.get("/media-community.json", (c) =>
  c.json({ version: 1, posts: [] }, 200, {
    "Cache-Control": "public, max-age=30, s-maxage=30",
    "CDN-Cache-Control": "public, max-age=30, s-maxage=30",
  }),
);

mediaCommunityApi.use("*", requireAuth);

mediaCommunityApi.post("/", (c) =>
  c.json({ error: "media_community_sharing_paused" }, 503),
);

mediaCommunityApi.post("/:id/like", (c) =>
  c.json({ error: "media_community_sharing_paused" }, 503),
);

export { mediaCommunityApi, mediaCommunityPublic };
