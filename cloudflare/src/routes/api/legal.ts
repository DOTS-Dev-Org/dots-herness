import { Hono } from "hono";
import { zValidator } from "@hono/zod-validator";
import { z } from "zod";
import type { Env, AppVariables } from "../../env";
import { db } from "../../db/client";
import { clientIpFromRequest, recordAudit } from "../../lib/audit";
import {
  LEGAL_DOCUMENT_VERSIONS,
  isLegalSupportedLocale,
  InvalidLegalConsentError,
  optionalLegalUser,
  recordLegalConsent,
  type LegalDocumentKey,
  KVKK_RESPONSE_DEADLINE_DAYS,
} from "../../lib/legal";
import { rateLimit } from "../../middleware/rate-limit";
import { requireAuth } from "../../middleware/auth";
import { nowIso, uuid } from "../../db/client";
import {
  sendLegalDataRequestNotificationEmail,
  sendLegalDataRequestReceiptEmail,
} from "../../lib/email";

const legal = new Hono<{ Bindings: Env; Variables: AppVariables }>();

const documentKeys = Object.keys(LEGAL_DOCUMENT_VERSIONS) as [LegalDocumentKey, ...LegalDocumentKey[]];
const consentSchema = z.object({
  anonymous_id: z.string().uuid().optional(),
  purpose: z.string().min(1).max(80),
  action: z.enum(["accepted", "acknowledged", "granted", "denied", "withdrawn"]),
  document_key: z.enum(documentKeys),
  document_version: z.string().min(1).max(32),
  locale: z.string().min(2).max(10).optional(),
  source: z.string().min(1).max(40).default("web"),
});

const dataRequestSchema = z.object({
  request_type: z.enum(["access", "correction", "deletion", "objection", "transfer", "other"]),
  details: z.string().trim().min(1).max(5000),
  locale: z.string().min(2).max(10).optional(),
});

const dataRequestStatuses = ["received", "identity_pending", "in_review", "responded", "rejected", "closed"] as const;
const identityStatuses = ["pending", "verified", "failed", "not_required"] as const;
const adminDataRequestSchema = z.object({
  status: z.enum(dataRequestStatuses).optional(),
  identity_status: z.enum(identityStatuses).optional(),
  response_channel: z.string().trim().max(80).optional().nullable(),
  response_summary: z.string().trim().max(5000).optional().nullable(),
}).refine((value) => Object.values(value).some((item) => item !== undefined), {
  message: "At least one status or response field is required",
});

type LegalDocumentRow = {
  app_slug: string;
  document_key: "terms" | "privacy_notice";
  locale: string;
  version: string;
  body_markdown: string;
  sha256: string;
  r2_key: string;
  translation_status: "draft" | "approved" | "published";
  source_locale: string;
  created_at: string;
  published_at: string | null;
};

async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function assetURL(c: { req: { url: string }; env: Env }, key: string): string {
  const base = (c.env.API_PUBLIC_URL || new URL(c.req.url).origin).replace(/\/$/, "");
  const encodedKey = key.split("/").map((part) => encodeURIComponent(part)).join("/");
  return `${base}/assets/${encodedKey}`;
}

/**
 * Public, read-only legal Markdown.  A missing locale or an unapproved draft
 * is an error by design: callers must not silently display the Turkish text
 * for a language the user selected.
 */
legal.get(
  "/documents",
  rateLimit({ limit: 60, windowSeconds: 60, keyPrefix: "legal:documents" }),
  async (c) => {
    const locale = c.req.query("locale")?.trim() || "";
    if (!isLegalSupportedLocale(locale)) {
      return c.json({ error: "unsupported_legal_locale", supported_locales: [
        "tr", "en", "de", "es", "fr", "it", "ja", "ko", "nl", "pt", "ru", "zh-Hans",
        "ar", "bn", "hi", "id", "vi", "ur", "mr", "te", "ta", "fa", "pl", "uk",
        "th", "ms", "ro", "el", "cs", "hu",
      ] }, 400);
    }

    const requestedVersion = c.req.query("version")?.trim() || LEGAL_DOCUMENT_VERSIONS.terms;
    const { results } = await db(c.env)
      .prepare(
        `SELECT app_slug, document_key, locale, version, body_markdown, sha256,
                r2_key, translation_status, source_locale, created_at, published_at
           FROM legal_documents
          WHERE app_slug = 'dots-herness'
            AND locale = ?
            AND version = ?
            AND document_key IN ('terms', 'privacy_notice')`,
      )
      .bind(locale, requestedVersion)
      .all<LegalDocumentRow>();

    const rows = (results || []) as LegalDocumentRow[];
    const documents = new Map(rows.map((row) => [row.document_key, row]));
    const terms = documents.get("terms");
    const privacy = documents.get("privacy_notice");
    if (!terms || !privacy) {
      return c.json({ error: "legal_documents_unavailable", locale, version: requestedVersion }, 404);
    }
    if (terms.translation_status === "draft" || privacy.translation_status === "draft") {
      return c.json({ error: "legal_documents_pending_review", locale, version: requestedVersion }, 409);
    }
    if (terms.version !== privacy.version || terms.locale !== privacy.locale) {
      return c.json({ error: "legal_document_set_inconsistent", locale, version: requestedVersion }, 503);
    }

    const objects = await Promise.all([
      c.env.DOTSHERNESS_ASSETS.get(terms.r2_key),
      c.env.DOTSHERNESS_ASSETS.get(privacy.r2_key),
    ]);
    if (!objects[0] || !objects[1]) {
      return c.json({ error: "legal_document_asset_missing", locale, version: requestedVersion }, 503);
    }

    const [termsMarkdown, privacyMarkdown] = await Promise.all([objects[0].text(), objects[1].text()]);
    const [termsHash, privacyHash, termsD1Hash, privacyD1Hash] = await Promise.all([
      sha256Hex(termsMarkdown),
      sha256Hex(privacyMarkdown),
      sha256Hex(terms.body_markdown),
      sha256Hex(privacy.body_markdown),
    ]);
    if (
      termsHash !== terms.sha256 ||
      privacyHash !== privacy.sha256 ||
      termsD1Hash !== terms.sha256 ||
      privacyD1Hash !== privacy.sha256
    ) {
      console.error("legal document integrity mismatch", { locale, version: requestedVersion });
      return c.json({ error: "legal_document_integrity_error", locale, version: requestedVersion }, 503);
    }

    return c.json({
      app_slug: "dots-herness",
      locale,
      version: terms.version,
      documents: {
        terms: {
          markdown: termsMarkdown,
          sha256: termsHash,
          r2_key: terms.r2_key,
          r2_url: assetURL(c, terms.r2_key),
          translation_status: terms.translation_status,
          source_locale: terms.source_locale,
        },
        privacy_notice: {
          markdown: privacyMarkdown,
          sha256: privacyHash,
          r2_key: privacy.r2_key,
          r2_url: assetURL(c, privacy.r2_key),
          translation_status: privacy.translation_status,
          source_locale: privacy.source_locale,
        },
      },
    });
  },
);

legal.post(
  "/consents",
  rateLimit({ limit: 60, windowSeconds: 60, keyPrefix: "legal:consents" }),
  zValidator("json", consentSchema),
  async (c) => {
    const body = c.req.valid("json");
    const user = await optionalLegalUser(c);
    const anonymousId = user ? null : body.anonymous_id;
    if (!user && !anonymousId) {
      return c.json({ error: "consent_subject_required" }, 400);
    }

    try {
      const id = await recordLegalConsent(c.env, {
        userId: user?.id ?? null,
        anonymousId,
        purpose: body.purpose,
        action: body.action,
        documentKey: body.document_key,
        documentVersion: body.document_version,
        locale: body.locale,
        source: body.source,
        ip: clientIpFromRequest(c.req),
        userAgent: c.req.header("User-Agent") ?? null,
      });
      return c.json({ ok: true, id }, 201);
    } catch (error) {
      if (error instanceof Error && error.name === "LegalAcceptanceRequiredError") {
        return c.json({ error: "stale_legal_document", code: "stale_legal_document" }, 409);
      }
      if (error instanceof InvalidLegalConsentError) {
        return c.json({ error: "invalid_consent_event" }, 400);
      }
      console.error("legal consent record failed", error instanceof Error ? error.message : error);
      return c.json({ error: "consent_record_failed" }, 500);
    }
  },
);

legal.get("/consents", async (c) => {
  const user = await optionalLegalUser(c);
  if (!user) return c.json({ error: "Unauthorized" }, 401);

  const { results } = await db(c.env)
    .prepare(
      `SELECT id, purpose, action, document_key, document_version, locale, source, created_at
         FROM legal_consent_events
        WHERE user_id = ?
        ORDER BY created_at DESC
        LIMIT 200`,
    )
    .bind(user.id)
    .all();

  return c.json({ consents: results || [] });
});

/** Formal authenticated KVKK request intake with a recorded 30-day due date. */
legal.post(
  "/data-requests",
  requireAuth,
  rateLimit({ limit: 10, windowSeconds: 3600, keyPrefix: "legal:data-requests" }),
  zValidator("json", dataRequestSchema),
  async (c) => {
    const body = c.req.valid("json");
    const user = c.get("user");
    const receivedAt = nowIso();
    const dueAt = new Date(Date.now() + KVKK_RESPONSE_DEADLINE_DAYS * 24 * 60 * 60 * 1000).toISOString();
    const id = uuid();

    await db(c.env)
      .prepare(
        `INSERT INTO legal_data_requests (
           id, user_id, requester_email, request_type, details, locale,
           status, identity_status, received_at, due_at, ip, user_agent
         ) VALUES (?, ?, ?, ?, ?, ?, 'identity_pending', 'pending', ?, ?, ?, ?)`,
      )
      .bind(
        id,
        user.id,
        user.email,
        body.request_type,
        body.details,
        body.locale || "tr",
        receivedAt,
        dueAt,
        clientIpFromRequest(c.req),
        c.req.header("User-Agent") ?? null,
      )
      .run();

    await recordAudit(c.env, {
      actorUserId: user.id,
      actorEmail: user.email,
      action: "legal.data_request",
      entityType: "legal_data_request",
      entityId: id,
      metadata: { requestType: body.request_type, status: "identity_pending", dueAt },
      ip: clientIpFromRequest(c.req),
      userAgent: c.req.header("User-Agent") ?? null,
    });

    // Keep intake successful even if SMTP/Resend is temporarily unavailable;
    // the D1 record and due date are already durable and the admin list remains
    // the operational fallback.
    try {
      const emailResult = await sendLegalDataRequestNotificationEmail(c.env, {
        id,
        requesterEmail: user.email,
        requestType: body.request_type,
        details: body.details,
        locale: body.locale || "tr",
        receivedAt,
        dueAt,
      });
      await recordAudit(c.env, {
        actorUserId: user.id,
        actorEmail: user.email,
        action: "legal.data_request.notification_sent",
        entityType: "legal_data_request",
        entityId: id,
        metadata: { messageId: emailResult.messageId },
        ip: clientIpFromRequest(c.req),
        userAgent: c.req.header("User-Agent") ?? null,
      });
    } catch (error) {
      console.error(
        "legal data request notification failed",
        error instanceof Error ? error.message : error,
      );
    }

    // A requester-facing receipt is best effort because the durable D1 row is
    // already the authoritative record. When mail is configured, this gives
    // the requester a durable medium containing the ID and 30-day deadline.
    try {
      const receiptResult = await sendLegalDataRequestReceiptEmail(c.env, {
        id,
        requesterEmail: user.email,
        requestType: body.request_type,
        details: body.details,
        locale: body.locale || "tr",
        receivedAt,
        dueAt,
      });
      await recordAudit(c.env, {
        actorUserId: user.id,
        actorEmail: user.email,
        action: "legal.data_request.receipt_sent",
        entityType: "legal_data_request",
        entityId: id,
        metadata: { messageId: receiptResult.messageId },
        ip: clientIpFromRequest(c.req),
        userAgent: c.req.header("User-Agent") ?? null,
      });
    } catch (error) {
      console.error(
        "legal data request receipt failed",
        error instanceof Error ? error.message : error,
      );
    }

    return c.json({
      ok: true,
      request: {
        id,
        request_type: body.request_type,
        status: "identity_pending",
        identity_status: "pending",
        received_at: receivedAt,
        due_at: dueAt,
      },
    }, 201);
  },
);

legal.get("/data-requests", requireAuth, async (c) => {
  const user = c.get("user");
  const { results } = await db(c.env)
    .prepare(
      `SELECT id, request_type, details, locale, status, identity_status,
              received_at, due_at, responded_at, response_channel,
              response_summary, created_at, updated_at
         FROM legal_data_requests
        WHERE user_id = ?
        ORDER BY received_at DESC
        LIMIT 50`,
    )
    .bind(user.id)
    .all();
  return c.json({ requests: results || [] });
});

export { adminDataRequestSchema, dataRequestSchema };

export default legal;
