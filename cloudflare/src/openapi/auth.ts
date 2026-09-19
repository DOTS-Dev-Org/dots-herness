import { createRoute, z, type OpenAPIHono } from "@hono/zod-openapi";
import type { Env, AppVariables } from "../env";
import { accountHeader, authedSecurity, errorSchema, tokensSchema } from "./schemas";

type Stub = () => (c: unknown) => Response;

export function registerAuthOpenApi(app: OpenAPIHono<{ Bindings: Env; Variables: AppVariables }>, stub: Stub) {
  const routes = [
    createRoute({
      method: "post",
      path: "/api/auth/login",
      tags: ["Auth"],
      summary: "Email/password login",
      request: {
        body: {
          content: {
            "application/json": {
              schema: z.object({
                email: z.string().email(),
                password: z.string(),
                terms_version: z.string().min(1).max(32).optional(),
                privacy_notice_version: z.string().min(1).max(32).optional(),
                explicit_consent: z.boolean().optional(),
                explicit_consent_version: z.string().min(1).max(32).optional(),
                locale: z.string().min(2).max(10).optional(),
              }),
            },
          },
        },
      },
      responses: {
        200: { description: "Tokens (+ HttpOnly cookies for web)", content: { "application/json": { schema: tokensSchema } } },
        401: { description: "Invalid credentials", content: { "application/json": { schema: errorSchema } } },
      },
    }),
    createRoute({
      method: "post",
      path: "/api/auth/register",
      tags: ["Auth"],
      summary: "Register new user",
      request: {
        body: {
          content: {
            "application/json": {
              schema: z.object({
                email: z.string().email(),
                password: z.string().min(8),
                name: z.string().optional(),
                surname: z.string().optional(),
                terms_version: z.string().min(1).max(32),
                privacy_notice_version: z.string().min(1).max(32),
                explicit_consent: z.boolean().optional(),
                explicit_consent_version: z.string().min(1).max(32).optional(),
                locale: z.string().min(2).max(10),
              }),
            },
          },
        },
      },
      responses: { 200: { description: "Registered", content: { "application/json": { schema: tokensSchema } } } },
    }),
    createRoute({
      method: "post",
      path: "/api/auth/refresh",
      tags: ["Auth"],
      summary: "Refresh access token",
      description: "Web: refresh cookie. Mobile/desktop: JSON `{ refresh_token }`.",
      request: {
        body: {
          content: {
            "application/json": {
              schema: z.object({ refresh_token: z.string().optional() }),
            },
          },
        },
      },
      responses: { 200: { description: "New tokens", content: { "application/json": { schema: tokensSchema } } } },
    }),
    createRoute({
      method: "post",
      path: "/api/auth/desktop/exchange",
      tags: ["Auth"],
      summary: "Exchange a one-time PKCE OAuth handoff code",
      request: {
        body: {
          content: {
            "application/json": {
              schema: z.object({
                code: z.string().min(43).max(128),
                code_verifier: z.string().min(43).max(128),
                client: z.enum(["desktop", "mobile"]),
              }),
            },
          },
        },
      },
      responses: {
        200: { description: "Tokens", content: { "application/json": { schema: tokensSchema } } },
        401: { description: "Invalid or expired handoff", content: { "application/json": { schema: errorSchema } } },
      },
    }),
    createRoute({
      method: "post",
      path: "/api/auth/logout",
      tags: ["Auth"],
      summary: "Logout (revoke refresh, clear cookies)",
      security: authedSecurity,
      responses: { 200: { description: "Logged out" } },
    }),
    createRoute({
      method: "post",
      path: "/api/auth/google",
      tags: ["Auth"],
      summary: "Google sign-in (mobile)",
      request: {
        body: {
          content: {
            "application/json": {
              schema: z.object({
                id_token: z.string(),
                terms_version: z.string().min(1).max(32).optional(),
                privacy_notice_version: z.string().min(1).max(32).optional(),
                explicit_consent: z.boolean().optional(),
                explicit_consent_version: z.string().min(1).max(32).optional(),
                locale: z.string().min(2).max(10).optional(),
              }),
            },
          },
        },
      },
      responses: { 200: { description: "Tokens", content: { "application/json": { schema: tokensSchema } } } },
    }),
    createRoute({
      method: "get",
      path: "/api/auth/google",
      tags: ["Auth"],
      summary: "Start Google OAuth (browser redirect)",
      request: {
        query: z.object({
          client: z.enum(["web", "desktop", "mobile"]).optional(),
          code_challenge: z.string().min(43).max(128).optional(),
          client_state: z.string().min(1).max(256).optional(),
          terms_version: z.string().min(1).max(32).optional(),
          privacy_notice_version: z.string().min(1).max(32).optional(),
          explicit_consent: z.enum(["0", "1"]).optional(),
          explicit_consent_version: z.string().min(1).max(32).optional(),
          locale: z.string().min(2).max(10).optional(),
        }),
      },
      responses: { 302: { description: "Redirect to Google" } },
    }),
    createRoute({
      method: "get",
      path: "/api/auth/github",
      tags: ["Auth"],
      summary: "Start GitHub OAuth",
      request: {
        query: z.object({
          client: z.enum(["web", "desktop", "mobile"]).optional(),
          code_challenge: z.string().min(43).max(128).optional(),
          client_state: z.string().min(1).max(256).optional(),
          terms_version: z.string().min(1).max(32).optional(),
          privacy_notice_version: z.string().min(1).max(32).optional(),
          explicit_consent: z.enum(["0", "1"]).optional(),
          explicit_consent_version: z.string().min(1).max(32).optional(),
          locale: z.string().min(2).max(10).optional(),
        }),
      },
      responses: { 302: { description: "Redirect to GitHub" } },
    }),
    createRoute({
      method: "post",
      path: "/api/auth/forgot-password",
      tags: ["Auth"],
      request: {
        body: { content: { "application/json": { schema: z.object({ email: z.string().email() }) } } },
      },
      responses: { 200: { description: "Email sent if account exists" } },
    }),
    createRoute({
      method: "post",
      path: "/api/auth/reset-password",
      tags: ["Auth"],
      request: {
        body: {
          content: {
            "application/json": {
              schema: z.object({ email: z.string().email(), code: z.string(), password: z.string() }),
            },
          },
        },
      },
      responses: { 200: { description: "Password updated" } },
    }),
    createRoute({
      method: "post",
      path: "/api/auth/qr/create",
      tags: ["Auth", "QR"],
      summary: "Create QR login session",
      responses: {
        200: {
          description: "QR session",
          content: {
            "application/json": {
              schema: z.object({
                sessionId: z.string(),
                qrUrl: z.string(),
                shortCode: z.string(),
                expiresAt: z.string(),
              }),
            },
          },
        },
      },
    }),
    createRoute({
      method: "get",
      path: "/api/auth/qr/poll",
      tags: ["Auth", "QR"],
      summary: "Poll QR session (mobile/desktop)",
      request: {
        query: z.object({ sid: z.string(), secret: z.string().optional() }),
      },
      responses: {
        200: {
          description: "pending | confirmed with tokens",
          content: { "application/json": { schema: z.record(z.unknown()) } },
        },
      },
    }),
    createRoute({
      method: "get",
      path: "/api/auth/qr/poll-code",
      tags: ["Auth", "QR"],
      summary: "Complete QR login using the manual 6-character fallback code",
      request: {
        query: z.object({ code: z.string() }),
      },
      responses: {
        200: {
          description: "pending | confirmed with tokens",
          content: { "application/json": { schema: z.record(z.unknown()) } },
        },
      },
    }),
    createRoute({
      method: "get",
      path: "/api/auth/qr/preview",
      tags: ["Auth", "QR"],
      summary: "Preview QR session before explicit confirm (no secrets)",
      request: {
        query: z.object({ sid: z.string() }),
      },
      responses: {
        200: {
          description: "pending session metadata",
          content: {
            "application/json": {
              schema: z.object({
                status: z.literal("pending"),
                expires_at: z.string(),
              }),
            },
          },
        },
        404: { description: "Not found" },
        410: { description: "Expired" },
      },
    }),
    createRoute({
      method: "post",
      path: "/api/auth/qr/confirm",
      tags: ["Auth", "QR"],
      summary: "Confirm QR from logged-in web session",
      security: authedSecurity,
      request: {
        body: { content: { "application/json": { schema: z.object({ sessionId: z.string() }) } } },
      },
      responses: { 200: { description: "Confirmed" } },
    }),
  ];

  for (const route of routes) {
    app.openapi(route, stub() as never);
  }
}
