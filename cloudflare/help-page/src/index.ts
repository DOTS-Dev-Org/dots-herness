import { Hono } from "hono";
import { harnessHelp } from "../../src/routes/harness-help";

const app = new Hono();

app.use("*", async (c, next) => {
  await next();
  c.header("X-Content-Type-Options", "nosniff");
  c.header("X-Frame-Options", "DENY");
  c.header("Referrer-Policy", "no-referrer");
  c.header("Permissions-Policy", "camera=(), microphone=(), geolocation=()");
  c.header("Content-Security-Policy", "frame-ancestors 'none'; base-uri 'none'");
  c.header("Strict-Transport-Security", "max-age=31536000; includeSubDomains");
});

app.route("/harness", harnessHelp);

export default app;
