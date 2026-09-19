import { Hono } from "hono";
import { OpenAPIHono } from "@hono/zod-openapi";
import { apiReference } from "@scalar/hono-api-reference";
import type { Env, AppVariables } from "../env";
import { registerAuthOpenApi } from "./auth";
import { registerUserOpenApi } from "./user";
import { registerTeamOpenApi } from "./team";
import { registerProviderOpenApi, registerAitrackOpenApi } from "./provider-aitrack";
import { registerAdminAuditPublicOpenApi, registerRestOpenApi } from "./admin-rest";
import { registerBillingOpenApi } from "./billing";
import { registerLegalOpenApi } from "./legal";

const API_SERVER = "https://dotsherness-unified-backend.dotsherness-unified-backend.workers.dev";

type SpecEnv = { Bindings: Env; Variables: AppVariables };

function buildSpecApp() {
  const specApp = new OpenAPIHono<SpecEnv>();
  const stub = () => () => new Response(null, { status: 501 });

  specApp.openAPIRegistry.registerComponent("securitySchemes", "bearerAuth", {
    type: "http",
    scheme: "bearer",
    bearerFormat: "JWT",
    description: "Mobile/desktop: Authorization: Bearer <access_token>",
  });
  specApp.openAPIRegistry.registerComponent("securitySchemes", "cookieAuth", {
    type: "apiKey",
    in: "cookie",
    name: "dotsherness_access",
    description: "Web SPA: credentials include",
  });

  registerAuthOpenApi(specApp, stub);
  registerUserOpenApi(specApp, stub);
  registerTeamOpenApi(specApp, stub);
  registerProviderOpenApi(specApp, stub);
  registerAitrackOpenApi(specApp, stub);
  registerAdminAuditPublicOpenApi(specApp, stub);
  registerRestOpenApi(specApp, stub);
  registerBillingOpenApi(specApp, stub);
  registerLegalOpenApi(specApp, stub);

  return specApp.getOpenAPIDocument({
    openapi: "3.0.0",
    info: {
      title: "AI Watcher API",
      version: "1.0.0",
      description:
        "Unified backend for web, mobile (aitrack), and desktop. Auth: web uses HttpOnly cookies; mobile/desktop use Bearer JWT. Workspace: optional `X-Workspace-Id` header.",
    },
    servers: [{ url: API_SERVER }],
    tags: [
      { name: "Auth", description: "Authentication and OAuth" },
      { name: "QR", description: "QR cross-device login" },
      { name: "User", description: "Profile, usage, sessions" },
      { name: "Team", description: "Workspace team management" },
      { name: "Provider", description: "AI provider connections" },
      { name: "Aitrack", description: "Mobile/desktop sync and billing" },
      { name: "AdminREST", description: "PostgREST-compatible CRUD on D1" },
      { name: "Billing", description: "Mobile IAP receipt verification (StoreKit2, Play Billing)" },
      { name: "Legal", description: "KVKK requests, legal acceptance and cookie-consent evidence" },
    ],
  });
}

let cachedDocument: ReturnType<typeof buildSpecApp> | null = null;

function getDocument() {
  if (!cachedDocument) cachedDocument = buildSpecApp();
  return cachedDocument;
}

/** Serves /openapi.json and /doc (Scalar UI). Spec is generated from route metadata only. */
export function createOpenApiRoutes() {
  const app = new Hono<{ Bindings: Env }>();

  app.get("/openapi.json", (c) => c.json(getDocument()));

  app.get(
    "/doc",
    apiReference({
      theme: "saturn",
      spec: { url: "/openapi.json" },
      pageTitle: "AI Watcher API",
    })
  );

  return app;
}
