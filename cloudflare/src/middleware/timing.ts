import { createMiddleware } from "hono/factory";
import type { Env, AppVariables } from "../env";

const SLOW_REQUEST_MS = 200;

/** Logs requests slower than 200ms (or all when LOG_SLOW_REQUESTS=1). */
export const timingMiddleware = createMiddleware<{ Bindings: Env; Variables: AppVariables }>(
  async (c, next) => {
    const started = Date.now();
    await next();
    const ms = Date.now() - started;
    const forceLog = c.env.LOG_SLOW_REQUESTS === "1";
    if (forceLog || ms >= SLOW_REQUEST_MS) {
      console.warn(`[http:${forceLog ? "trace" : "slow"}] ${c.req.method} ${c.req.path} ${ms}ms ${c.res.status}`);
    }
  }
);
