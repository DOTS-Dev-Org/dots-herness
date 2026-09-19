import { z } from "@hono/zod-openapi";

export const errorSchema = z.object({ error: z.string() }).openapi("Error");

export const tokensSchema = z
  .object({
    access_token: z.string(),
    refresh_token: z.string(),
  })
  .openapi("Tokens");

export const accountHeader = z.object({
  "X-Workspace-Id": z.string().uuid().optional().openapi({
    description: "Active workspace id (multi-workspace). Legacy: X-Account-Id also accepted.",
  }),
});

/** Bearer OR cookie auth (either satisfies requireAuth). */
export const authedSecurity = [{ bearerAuth: [] }, { cookieAuth: [] }] as Array<
  Record<string, string[]>
>;
