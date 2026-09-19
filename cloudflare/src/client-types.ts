import { Hono } from "hono";
import type { Env, AppVariables } from "./env";
import { securityGuardMiddleware } from "./middleware/security-guard";
import authRoutes from "./routes/api/auth";
import userRoutes from "./routes/api/user";
import teamRoutes from "./routes/api/team";
import acceptInviteRoutes from "./routes/api/team-accept-invite";
import adminRoutes from "./routes/api/admin";
import restRoutes, { publicRest } from "./routes/api/rest";
import publicRoutes from "./routes/api/public";
import { providerRoutes, scrapeRoutes } from "./routes/api/provider";
import auditRoutes from "./routes/api/audit";
import billingRoutes from "./routes/api/billing";
import legalRoutes from "./routes/api/legal";
import aitrackRoutes from "./routes/aitrack/index";
import { marketplaceApi } from "./routes/api/marketplace";

export const apiApp = new Hono<{ Bindings: Env; Variables: AppVariables }>()
  .use("*", securityGuardMiddleware)
  .route("/auth", authRoutes)
  .route("/user", userRoutes)
  .route("/team", acceptInviteRoutes)
  .route("/team", teamRoutes)
  .route("/admin", adminRoutes)
  // ponytail: /rest/* runs requireAuth on every subpath; mount public reads outside /rest
  .route("/public-rest", publicRest)
  .route("/rest/public", publicRest)
  .route("/rest", restRoutes)
  .route("/provider", providerRoutes)
  .route("/scrape", scrapeRoutes)
  .route("/audit", auditRoutes)
  .route("/billing", billingRoutes)
  .route("/legal", legalRoutes)
  .route("/marketplace", marketplaceApi)
  .route("/", publicRoutes);

export const aitrackApp = aitrackRoutes;

export type ApiAppType = typeof apiApp;
export type AitrackAppType = typeof aitrackApp;
