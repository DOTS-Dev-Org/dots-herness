import type { Context } from "hono";
import type { Env, AppVariables } from "../env";
import { db, nowIso, uuid } from "../db/client";
import { getAccessTokenFromCookie } from "./auth-cookies";
import { verifyAccessToken } from "./jwt";
import { getActiveAuthUser } from "./users";

/**
 * Legal documents are versioned independently from the application build.
 * A version is not a substitute for counsel approval; it is the immutable
 * identifier that associates an event with the declared document revision.
 */
export const LEGAL_DOCUMENT_VERSIONS = {
  terms: "2026-08-26",
  privacy_notice: "2026-08-26",
  explicit_consent: "2026-08-26",
  cookies: "2026-08-26",
  precontract: "2026-08-26",
  distance_sales: "2026-08-26",
  refund: "2026-08-26",
  subscription: "2026-08-26",
} as const;

export type LegalDocumentKey = keyof typeof LEGAL_DOCUMENT_VERSIONS;
export type LegalConsentAction = "accepted" | "acknowledged" | "granted" | "denied" | "withdrawn";
/** English and the other translations remain readable but are not yet approved for binding acceptance. */
export const LEGAL_MASTER_LOCALES = ["tr"] as const;

/**
 * Public legal-document reads accept only the concrete mobile locales.  The
 * mobile `system` choice is resolved on-device and is never sent to this API.
 */
export const LEGAL_SUPPORTED_LOCALES = [
  "tr", "en", "de", "es", "fr", "it", "ja", "ko", "nl", "pt", "ru", "zh-Hans",
  "ar", "bn", "hi", "id", "vi", "ur", "mr", "te", "ta", "fa", "pl", "uk",
  "th", "ms", "ro", "el", "cs", "hu",
] as const;
export type LegalSupportedLocale = (typeof LEGAL_SUPPORTED_LOCALES)[number];

export function isLegalSupportedLocale(value: string): value is LegalSupportedLocale {
  return LEGAL_SUPPORTED_LOCALES.includes(value as LegalSupportedLocale);
}

/**
 * Consumer distance-service withdrawal period used by the deferred-entitlement
 * path when the customer does not request immediate performance. Keep this
 * separate from the optional request itself: payment is not conditioned on a
 * waiver of the withdrawal period.
 */
export const CONSUMER_WITHDRAWAL_PERIOD_DAYS = 14;
export const KVKK_RESPONSE_DEADLINE_DAYS = 30;
/**
 * Subscription termination requests received through the online channel are
 * tracked against the consumer-information deadline used by the current
 * Ministry of Trade subscription guidance.
 */
export const SUBSCRIPTION_CANCELLATION_RESPONSE_DEADLINE_DAYS = 7;
export const PREPAID_REFUND_DEADLINE_DAYS = 15;

/**
 * New-account creation stays closed until the published legal texts and
 * company identity have been approved. Existing sessions are not interrupted.
 */
export function legalPublicationEnabled(env: Pick<Env, "LEGAL_PUBLICATION_ENABLED">): boolean {
  return env.LEGAL_PUBLICATION_ENABLED === "1";
}

type LegalConsentPurposeRule = {
  documentKeys: readonly LegalDocumentKey[];
  actions: readonly LegalConsentAction[];
};

const consentPurposeRules: Record<string, LegalConsentPurposeRule> = {
  "terms.acceptance": { documentKeys: ["terms"], actions: ["accepted"] },
  "privacy.notice": { documentKeys: ["privacy_notice"], actions: ["acknowledged"] },
  "optional.analytics_product": { documentKeys: ["explicit_consent"], actions: ["granted", "denied", "withdrawn"] },
  "precontract.acknowledgement": { documentKeys: ["precontract"], actions: ["acknowledged"] },
  "distance_sales.acceptance": { documentKeys: ["distance_sales"], actions: ["accepted"] },
  "refund_policy.acknowledgement": { documentKeys: ["refund"], actions: ["acknowledged"] },
  "subscription.acceptance": { documentKeys: ["subscription"], actions: ["accepted"] },
  // Older store-purchase evidence used the refund revision for this separate
  // request. Keep it readable while web checkout uses distance_sales.
  "digital_service.immediate_performance": { documentKeys: ["distance_sales", "refund"], actions: ["accepted"] },
  "cookie.necessary": { documentKeys: ["cookies"], actions: ["granted", "denied", "withdrawn"] },
  "cookie.functional": { documentKeys: ["cookies"], actions: ["granted", "denied", "withdrawn"] },
  "cookie.analytics": { documentKeys: ["cookies"], actions: ["granted", "denied", "withdrawn"] },
  "cookie.marketing": { documentKeys: ["cookies"], actions: ["granted", "denied", "withdrawn"] },
};

export type RequiredLegalAcceptance = {
  termsVersion: string;
  privacyNoticeVersion: string;
  explicitConsentVersion?: string | null;
  explicitConsentGranted?: boolean;
  locale?: string | null;
  source?: string | null;
};

export class LegalAcceptanceRequiredError extends Error {
  readonly code = "legal_acceptance_required";

  constructor(message = "Current legal documents must be accepted before continuing.") {
    super(message);
    this.name = "LegalAcceptanceRequiredError";
  }
}

export class InvalidLegalConsentError extends Error {
  constructor(message = "The legal consent purpose, document and action do not match.") {
    super(message);
    this.name = "InvalidLegalConsentError";
  }
}

function isLegalMasterLocale(locale: string | null | undefined): boolean {
  return Boolean(locale && LEGAL_MASTER_LOCALES.includes(locale as (typeof LEGAL_MASTER_LOCALES)[number]));
}

function assertBindingLocale(locale: string | null | undefined): void {
  if (!isLegalMasterLocale(locale)) {
    throw new LegalAcceptanceRequiredError("The Turkish legal master must be used for binding acceptance.");
  }
}

export function validateLegalConsentPurpose(input: {
  purpose: string;
  action: LegalConsentAction;
  documentKey: LegalDocumentKey;
}): void {
  const rule = consentPurposeRules[input.purpose];
  if (!rule || !rule.documentKeys.includes(input.documentKey) || !rule.actions.includes(input.action)) {
    throw new InvalidLegalConsentError();
  }
}

export function validateRequiredLegalAcceptance(input: RequiredLegalAcceptance): void {
  if (input.termsVersion !== LEGAL_DOCUMENT_VERSIONS.terms) {
    throw new LegalAcceptanceRequiredError("Current terms must be accepted.");
  }
  if (input.privacyNoticeVersion !== LEGAL_DOCUMENT_VERSIONS.privacy_notice) {
    throw new LegalAcceptanceRequiredError("The current privacy notice must be acknowledged.");
  }
  if (input.explicitConsentGranted && input.explicitConsentVersion !== LEGAL_DOCUMENT_VERSIONS.explicit_consent) {
    throw new LegalAcceptanceRequiredError("The current explicit-consent text must be accepted.");
  }
  assertBindingLocale(input.locale);
}

export type PaymentLegalAcceptance = {
  termsVersion: string;
  precontractVersion: string;
  distanceSalesVersion: string;
  refundVersion: string;
  subscriptionVersion: string;
  immediatePerformanceRequested: boolean;
  acceptedLocale?: string | null;
};

export type PlanChangeLegalAcceptance = {
  termsVersion: string;
  subscriptionVersion: string;
  acceptedLocale?: string | null;
};

export function validatePlanChangeLegalAcceptance(input: PlanChangeLegalAcceptance): void {
  if (input.termsVersion !== LEGAL_DOCUMENT_VERSIONS.terms) {
    throw new LegalAcceptanceRequiredError("Current terms must be accepted before changing plans.");
  }
  if (input.subscriptionVersion !== LEGAL_DOCUMENT_VERSIONS.subscription) {
    throw new LegalAcceptanceRequiredError("Current subscription terms must be accepted before changing plans.");
  }
  assertBindingLocale(input.acceptedLocale);
}

export function validatePaymentLegalAcceptance(input: PaymentLegalAcceptance): void {
  if (input.termsVersion !== LEGAL_DOCUMENT_VERSIONS.terms) {
    throw new LegalAcceptanceRequiredError("Current terms must be accepted before payment.");
  }
  if (input.precontractVersion !== LEGAL_DOCUMENT_VERSIONS.precontract) {
    throw new LegalAcceptanceRequiredError("Current pre-contract information must be acknowledged.");
  }
  if (input.distanceSalesVersion !== LEGAL_DOCUMENT_VERSIONS.distance_sales) {
    throw new LegalAcceptanceRequiredError("The current distance sales agreement must be accepted.");
  }
  if (input.refundVersion !== LEGAL_DOCUMENT_VERSIONS.refund) {
    throw new LegalAcceptanceRequiredError("The current cancellation and refund policy must be acknowledged.");
  }
  if (input.subscriptionVersion !== LEGAL_DOCUMENT_VERSIONS.subscription) {
    throw new LegalAcceptanceRequiredError("Current subscription terms must be accepted.");
  }
  // Immediate performance is an optional, separately evidenced consumer
  // request. If it is not selected, the paid order remains recorded but its
  // entitlement is deferred until the withdrawal period has elapsed.
  assertBindingLocale(input.acceptedLocale);
}

export type RecordLegalConsentOptions = {
  userId?: string | null;
  anonymousId?: string | null;
  purpose: string;
  action: LegalConsentAction;
  documentKey: LegalDocumentKey;
  documentVersion: string;
  locale?: string | null;
  source: string;
  ip?: string | null;
  userAgent?: string | null;
};

export async function recordLegalConsent(env: Env, options: RecordLegalConsentOptions): Promise<string> {
  if (!options.userId && !options.anonymousId) {
    throw new Error("legal_consent_subject_required");
  }
  validateLegalConsentPurpose(options);
  const isOptionalConsentWithdrawal =
    options.purpose === "optional.analytics_product" &&
    (options.action === "denied" || options.action === "withdrawn");
  if (!options.purpose.startsWith("cookie.") && !isOptionalConsentWithdrawal) {
    assertBindingLocale(options.locale);
  }
  if (LEGAL_DOCUMENT_VERSIONS[options.documentKey] !== options.documentVersion) {
    throw new LegalAcceptanceRequiredError("Unknown or stale legal document version.");
  }

  const id = uuid();
  await db(env)
    .prepare(
      `INSERT INTO legal_consent_events (
         id, user_id, anonymous_id, purpose, action, document_key,
         document_version, locale, source, ip, user_agent, created_at
       ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    )
    .bind(
      id,
      options.userId ?? null,
      options.anonymousId ?? null,
      options.purpose,
      options.action,
      options.documentKey,
      options.documentVersion,
      options.locale || "tr",
      options.source,
      options.ip ?? null,
      options.userAgent ?? null,
      nowIso(),
    )
    .run();

  return id;
}

export async function recordLegalConsents(
  env: Env,
  subject: Pick<RecordLegalConsentOptions, "userId" | "anonymousId" | "locale" | "source" | "ip" | "userAgent">,
  events: Array<Pick<RecordLegalConsentOptions, "purpose" | "action" | "documentKey" | "documentVersion">>,
): Promise<void> {
  for (const event of events) {
    await recordLegalConsent(env, { ...subject, ...event });
  }
}

export async function hasCurrentRequiredLegalAcceptance(env: Env, userId: string): Promise<boolean> {
  const [terms, privacy] = await Promise.all([
    db(env)
      .prepare(
        `SELECT action FROM legal_consent_events
          WHERE user_id = ? AND purpose = 'terms.acceptance'
            AND document_key = 'terms' AND document_version = ? AND locale = 'tr'
          ORDER BY created_at DESC LIMIT 1`,
      )
      .bind(userId, LEGAL_DOCUMENT_VERSIONS.terms)
      .first<{ action: LegalConsentAction }>(),
    db(env)
      .prepare(
        `SELECT action FROM legal_consent_events
          WHERE user_id = ? AND purpose = 'privacy.notice'
            AND document_key = 'privacy_notice' AND document_version = ? AND locale = 'tr'
          ORDER BY created_at DESC LIMIT 1`,
      )
      .bind(userId, LEGAL_DOCUMENT_VERSIONS.privacy_notice)
      .first<{ action: LegalConsentAction }>(),
  ]);
  return terms?.action === "accepted" && privacy?.action === "acknowledged";
}

type AuthContext = Context<{ Bindings: Env; Variables: AppVariables }>;

/** Resolve an optional session for the public cookie-consent endpoint. */
export async function optionalLegalUser(c: AuthContext): Promise<AppVariables["user"] | null> {
  const authorization = c.req.header("Authorization");
  const bearer = authorization?.match(/^Bearer\s+(\S+)/i)?.[1];
  const token = bearer || getAccessTokenFromCookie(c);
  if (!token) return null;

  try {
    const claims = await verifyAccessToken(c.env, token);
    return getActiveAuthUser(c.env, claims.userId);
  } catch {
    return null;
  }
}
