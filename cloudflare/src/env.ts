export type Env = {
  DOTSHERNESS_DB?: D1Database;
  DOTSHERNESS_ASSETS: R2Bucket;
  /**
   * Self-hosted usage store (Redis live state + Postgres window rollups).
   * Absent in local/dev, in which case the mirror write is skipped entirely
   * and D1 stays the only store.
   */
  VPS_API_URL?: string;
  VPS_API_SECRET?: string;
  JWT_SECRET?: string;
  JWT_ISSUER?: string;
  PAYTR_MERCHANT_ID?: string;
  PAYTR_MERCHANT_KEY?: string;
  PAYTR_MERCHANT_SALT?: string;
  PAYTR_TEST_MODE?: string;
  PAYTR_OK_URL?: string;
  PAYTR_FAIL_URL?: string;
  /** Set to "1" only after company identity, tax, VAT and invoicing checks are verified. */
  PAYTR_LEGAL_SALES_ENABLED?: string;
  /** Explicit precondition for displaying and charging a tax-inclusive consumer price. */
  PAYTR_TAX_INCLUSIVE_CONFIRMED?: string;
  /** Explicit precondition for the verified invoice/e-archive flow. */
  PAYTR_INVOICE_FLOW_CONFIRMED?: string;
  /** Explicit precondition for delivering order/contracts on a durable medium. */
  PAYTR_DURABLE_DELIVERY_CONFIRMED?: string;
  /** Set to "1" only after the published legal texts and company identity are counsel-approved. */
  LEGAL_PUBLICATION_ENABLED?: string;
  GOOGLE_CLIENT_ID?: string;
  GOOGLE_CLIENT_SECRET?: string;
  GOOGLE_CLIENT_IDS?: string;
  GITHUB_CLIENT_ID?: string;
  GITHUB_CLIENT_SECRET?: string;
  FRONTEND_URL?: string;
  /** Native desktop OAuth handoff callback, e.g. herness://oauth/desktop. */
  DESKTOP_OAUTH_CALLBACK_URL?: string;
  /** Set to "1" only for local Wrangler development origins. */
  ALLOW_LOCAL_ORIGINS?: string;
  /** Published contact address used in server-generated account and order emails. */
  LEGAL_CONTACT_EMAIL?: string;
  API_PUBLIC_URL?: string;
  /** Public publisher id used for marketplace artifact signatures. */
  MARKETPLACE_PUBLISHER_ID?: string;
  /** Base64 raw Ed25519 public key for the DOTS marketplace signer. */
  MARKETPLACE_SIGNING_PUBLIC_KEY?: string;
  /** JSON Ed25519 JWK private key kept as a Wrangler secret. */
  MARKETPLACE_SIGNING_PRIVATE_KEY?: string;
  /** CI-only secret used by the trusted artifact upload job. */
  MARKETPLACE_CI_SECRET?: string;
  /** GitHub Actions OIDC audience accepted for artifact callbacks. */
  MARKETPLACE_CI_OIDC_AUDIENCE?: string;
  /** Exact GitHub repository allowed to publish Marketplace artifacts. */
  MARKETPLACE_CI_REPOSITORY?: string;
  /** Workflow path allowed to publish Marketplace artifacts. */
  MARKETPLACE_CI_WORKFLOW?: string;
  /** Maximum source/artifact payload accepted by the Worker in bytes. */
  MARKETPLACE_MAX_UPLOAD_BYTES?: string;
  /** GitHub Actions workflow-dispatch endpoint, kept as a secret/configured var. */
  MARKETPLACE_BUILD_DISPATCH_URL?: string;
  /** GitHub App installation token or narrowly scoped workflow token. */
  MARKETPLACE_BUILD_DISPATCH_TOKEN?: string;
  MARKETPLACE_BUILD_DISPATCH_REF?: string;
  SMTP_HOST?: string;
  SMTP_PORT?: string;
  SMTP_FROM_EMAIL?: string;
  SMTP_FROM_NAME?: string;
  SMTP_USERNAME?: string;
  SMTP_PASSWORD?: string;
  RESEND_API_KEY?: string;
  /** Firebase service account JSON (project dotsherness-app). `wrangler secret put FCM_SERVICE_ACCOUNT_JSON` */
  FCM_SERVICE_ACCOUNT_JSON?: string;
  /** watchOS APNs bundle id, used to exchange raw APNs tokens for FCM tokens. Default com.dots.aiwatcher.watchapp */
  WATCH_APNS_BUNDLE_ID?: string;
  /** "1" while the watch app is signed with a development/sandbox APNs cert */
  WATCH_APNS_SANDBOX?: string;
  /** Set to "1" to log every request duration via timingMiddleware */
  LOG_SLOW_REQUESTS?: string;
  // Server-side store verification is required before a mobile purchase can
  // activate a plan. Store endpoints fail closed while these are absent.
  APPLE_ISSUER_ID?: string;
  APPLE_KEY_ID?: string;
  APPLE_PRIVATE_KEY?: string; // .p8 contents, `wrangler secret put APPLE_PRIVATE_KEY`
  APPLE_BUNDLE_ID?: string; // com.dots.aiwatcher
  GOOGLE_PLAY_SERVICE_ACCOUNT_JSON?: string;
  GOOGLE_PLAY_PACKAGE_NAME?: string;
};

export type AuthUser = {
  id: string;
  email: string;
  role: string;
  name?: string;
  surname?: string;
};

export type AppVariables = {
  user: AuthUser;
  workspaceId?: string;
  workspaceRole?: string;
};
