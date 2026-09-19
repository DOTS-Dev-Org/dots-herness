import type { Env } from "../env";
import { sendEmail, type SmtpSendResult } from "./smtp";
import { escapeHtml } from "./html";

function legalReplyTo(env: Env): string {
  return env.LEGAL_CONTACT_EMAIL?.trim() || "supportherness@dots.net.tr";
}

export type LegalDataRequestNotification = {
  id: string;
  requesterEmail: string;
  requestType: string;
  details: string;
  locale: string;
  receivedAt: string;
  dueAt: string;
};

const legalDataRequestTypeLabels: Record<string, string> = {
  access: "Erişim/kopya",
  correction: "Düzeltme",
  deletion: "Silme/yok etme",
  objection: "İşlemeye itiraz",
  transfer: "Aktarım bilgisi",
  other: "Diğer",
};

const cancellationEffectLabels: Record<string, string> = {
  end_of_period: "Dönem sonunda sona erdirme",
  immediate: "Hemen sona erdirme talebi",
};

/**
 * Notify the configured controller contact when a formal KVKK request is
 * received. The D1 row remains the source of truth: a mail outage must not
 * make the request disappear or change its recorded 30-day deadline.
 */
export async function sendLegalDataRequestNotificationEmail(
  env: Env,
  request: LegalDataRequestNotification,
): Promise<SmtpSendResult> {
  const contact = legalReplyTo(env);
  const frontend = (env.FRONTEND_URL || "https://herness.dots.net.tr").replace(/\/$/, "");
  const adminUrl = `${frontend}/admin/legal-requests`;
  const safeAdminUrl = escapeHtml(adminUrl);
  const requestTypeLabel = legalDataRequestTypeLabels[request.requestType] || request.requestType;

  return sendEmail(env, {
    to: contact,
    subject: `Yeni KVKK başvurusu — ${request.id}`,
    replyTo: request.requesterEmail,
    text: [
      "Yeni bir KVKK ilgili kişi başvurusu alındı.",
      "",
      `Başvuru kimliği: ${request.id}`,
      `Başvurucu e-postası: ${request.requesterEmail}`,
      `Talep türü: ${requestTypeLabel}`,
      `Dil: ${request.locale}`,
      `Alındı: ${request.receivedAt}`,
      `Son cevap tarihi: ${request.dueAt}`,
      "",
      "Talep ayrıntısı:",
      request.details,
      "",
      `Admin işlem ekranı: ${adminUrl}`,
      "Başvuru kaydı D1 üzerinde tutulur; kimlik doğrulaması ve gerekçeli yazılı/elektronik cevap süreci panelden tamamlanmalıdır.",
    ].join("\n"),
    html: `
      <p><strong>Yeni bir KVKK ilgili kişi başvurusu alındı.</strong></p>
      <ul>
        <li><strong>Başvuru kimliği:</strong> ${escapeHtml(request.id)}</li>
        <li><strong>Başvurucu e-postası:</strong> ${escapeHtml(request.requesterEmail)}</li>
        <li><strong>Talep türü:</strong> ${escapeHtml(requestTypeLabel)}</li>
        <li><strong>Dil:</strong> ${escapeHtml(request.locale)}</li>
        <li><strong>Alındı:</strong> ${escapeHtml(request.receivedAt)}</li>
        <li><strong>Son cevap tarihi:</strong> ${escapeHtml(request.dueAt)}</li>
      </ul>
      <p><strong>Talep ayrıntısı:</strong></p>
      <p style="white-space:pre-wrap">${escapeHtml(request.details)}</p>
      <p><a href="${safeAdminUrl}">Admin işlem ekranını aç</a></p>
      <p>Başvuru kaydı D1 üzerinde tutulur; kimlik doğrulaması ve gerekçeli yazılı/elektronik cevap süreci panelden tamamlanmalıdır.</p>
    `,
  });
}

/**
 * Give the requester a durable receipt for the formal KVKK application.
 * This message intentionally does not echo the request details; the D1 row
 * and authenticated account panel remain the source of truth for content.
 */
export async function sendLegalDataRequestReceiptEmail(
  env: Env,
  request: LegalDataRequestNotification,
): Promise<SmtpSendResult> {
  const frontend = (env.FRONTEND_URL || "https://herness.dots.net.tr").replace(/\/$/, "");
  const accountUrl = `${frontend}/dashboard`;
  const safeAccountUrl = escapeHtml(accountUrl);
  const requestTypeLabel = legalDataRequestTypeLabels[request.requestType] || request.requestType;
  const contact = legalReplyTo(env);

  return sendEmail(env, {
    to: request.requesterEmail,
    subject: `KVKK başvurunuz alındı — ${request.id}`,
    replyTo: contact,
    text: [
      "KVKK ilgili kişi başvurunuz alınmıştır.",
      "",
      `Başvuru kimliği: ${request.id}`,
      `Talep türü: ${requestTypeLabel}`,
      `Alındı: ${request.receivedAt}`,
      `Son cevap tarihi: ${request.dueAt}`,
      "",
      "Başvurunuzun kimlik doğrulama ve inceleme durumu hesabınızdaki KVKK başvuruları bölümünden takip edilebilir.",
      `Başvuru ekranı: ${accountUrl}`,
      `Sorularınız için: ${contact}`,
    ].join("\n"),
    html: `
      <p><strong>KVKK ilgili kişi başvurunuz alınmıştır.</strong></p>
      <ul>
        <li><strong>Başvuru kimliği:</strong> ${escapeHtml(request.id)}</li>
        <li><strong>Talep türü:</strong> ${escapeHtml(requestTypeLabel)}</li>
        <li><strong>Alındı:</strong> ${escapeHtml(request.receivedAt)}</li>
        <li><strong>Son cevap tarihi:</strong> ${escapeHtml(request.dueAt)}</li>
      </ul>
      <p>Kimlik doğrulama ve inceleme durumunu hesabınızdaki KVKK başvuruları bölümünden takip edebilirsiniz.</p>
      <p><a href="${safeAccountUrl}">KVKK başvurularımı görüntüle</a></p>
      <p>Sorularınız için: ${escapeHtml(contact)}</p>
    `,
  });
}

export type LegalDataRequestResponseNotification = {
  id: string;
  requesterEmail: string;
  requestType: string;
  status: string;
  responseChannel: string;
  responseSummary: string;
  respondedAt: string;
};

/** Send the recorded KVKK decision through a durable electronic channel. */
export async function sendLegalDataRequestResponseEmail(
  env: Env,
  response: LegalDataRequestResponseNotification,
): Promise<SmtpSendResult> {
  const frontend = (env.FRONTEND_URL || "https://herness.dots.net.tr").replace(/\/$/, "");
  const accountUrl = `${frontend}/dashboard`;
  const safeAccountUrl = escapeHtml(accountUrl);
  const requestTypeLabel = legalDataRequestTypeLabels[response.requestType] || response.requestType;
  const statusLabel = response.status === "rejected" ? "Reddedildi" : "Cevaplandı";

  return sendEmail(env, {
    to: response.requesterEmail,
    subject: `KVKK başvurunuza yanıt — ${response.id}`,
    replyTo: legalReplyTo(env),
    text: [
      "KVKK ilgili kişi başvurunuza ilişkin işlem tamamlandı.",
      "",
      `Başvuru kimliği: ${response.id}`,
      `Talep türü: ${requestTypeLabel}`,
      `Durum: ${statusLabel}`,
      `Cevap kanalı: ${response.responseChannel}`,
      `Cevap zamanı: ${response.respondedAt}`,
      "",
      "Cevap / gerekçe:",
      response.responseSummary,
      "",
      `Başvurularım: ${accountUrl}`,
      `Sorularınız için: ${legalReplyTo(env)}`,
    ].join("\n"),
    html: `
      <p><strong>KVKK ilgili kişi başvurunuza ilişkin işlem tamamlandı.</strong></p>
      <ul>
        <li><strong>Başvuru kimliği:</strong> ${escapeHtml(response.id)}</li>
        <li><strong>Talep türü:</strong> ${escapeHtml(requestTypeLabel)}</li>
        <li><strong>Durum:</strong> ${escapeHtml(statusLabel)}</li>
        <li><strong>Cevap kanalı:</strong> ${escapeHtml(response.responseChannel)}</li>
        <li><strong>Cevap zamanı:</strong> ${escapeHtml(response.respondedAt)}</li>
      </ul>
      <p><strong>Cevap / gerekçe:</strong></p>
      <p style="white-space:pre-wrap">${escapeHtml(response.responseSummary)}</p>
      <p><a href="${safeAccountUrl}">Başvurularımı görüntüle</a></p>
      <p>Sorularınız için: ${escapeHtml(legalReplyTo(env))}</p>
    `,
  });
}

export type SubscriptionCancellationRequestNotification = {
  id: string;
  requesterEmail: string;
  planSlug: string;
  requestedEffect: string;
  refundRequested: boolean;
  details: string;
  servicePeriodEndsAt: string | null;
  receivedAt: string;
  processingDueAt: string;
  refundDueAt: string | null;
};

/**
 * Notify the operator about an authenticated subscription cancellation
 * request. The request row is authoritative; mail delivery is deliberately
 * best effort and must not change the recorded seven/fifteen-day deadlines.
 */
export async function sendSubscriptionCancellationRequestNotificationEmail(
  env: Env,
  request: SubscriptionCancellationRequestNotification,
): Promise<SmtpSendResult> {
  const contact = legalReplyTo(env);
  const frontend = (env.FRONTEND_URL || "https://herness.dots.net.tr").replace(/\/$/, "");
  const adminUrl = `${frontend}/admin/subscription-cancellations`;
  const safeAdminUrl = escapeHtml(adminUrl);
  const effectLabel = cancellationEffectLabels[request.requestedEffect] || request.requestedEffect;
  const refundLine = request.refundDueAt
    ? `İade talebi son tarihi: ${request.refundDueAt}`
    : "İade talebi: Hayır";

  return sendEmail(env, {
    to: contact,
    subject: `Yeni abonelik iptal talebi — ${request.id}`,
    replyTo: request.requesterEmail,
    text: [
      "Yeni bir abonelik iptal talebi alındı.",
      "",
      `Talep kimliği: ${request.id}`,
      `Başvurucu e-postası: ${request.requesterEmail}`,
      `Plan: ${request.planSlug}`,
      `Talep: ${effectLabel}`,
      `İade talebi: ${request.refundRequested ? "Evet" : "Hayır"}`,
      `Mevcut dönem bitişi: ${request.servicePeriodEndsAt || "kayıtlı değil"}`,
      `Alındı: ${request.receivedAt}`,
      `İşlem son tarihi: ${request.processingDueAt}`,
      refundLine,
      "",
      "Talep ayrıntısı:",
      request.details || "Belirtilmedi",
      "",
      `Admin işlem ekranı: ${adminUrl}`,
      "Talep panelden incelenmeli; kabul, iptal ve varsa ödeme sağlayıcısı iadesi ayrıca kayda alınmalıdır.",
    ].join("\n"),
    html: `
      <p><strong>Yeni bir abonelik iptal talebi alındı.</strong></p>
      <ul>
        <li><strong>Talep kimliği:</strong> ${escapeHtml(request.id)}</li>
        <li><strong>Başvurucu e-postası:</strong> ${escapeHtml(request.requesterEmail)}</li>
        <li><strong>Plan:</strong> ${escapeHtml(request.planSlug)}</li>
        <li><strong>Talep:</strong> ${escapeHtml(effectLabel)}</li>
        <li><strong>İade talebi:</strong> ${request.refundRequested ? "Evet" : "Hayır"}</li>
        <li><strong>Mevcut dönem bitişi:</strong> ${escapeHtml(request.servicePeriodEndsAt || "kayıtlı değil")}</li>
        <li><strong>Alındı:</strong> ${escapeHtml(request.receivedAt)}</li>
        <li><strong>İşlem son tarihi:</strong> ${escapeHtml(request.processingDueAt)}</li>
        ${request.refundDueAt ? `<li><strong>İade talebi son tarihi:</strong> ${escapeHtml(request.refundDueAt)}</li>` : ""}
      </ul>
      <p><strong>Talep ayrıntısı:</strong></p>
      <p style="white-space:pre-wrap">${escapeHtml(request.details || "Belirtilmedi")}</p>
      <p><a href="${safeAdminUrl}">Admin işlem ekranını aç</a></p>
      <p>Talep panelden incelenmeli; kabul, iptal ve varsa ödeme sağlayıcısı iadesi ayrıca kayda alınmalıdır.</p>
    `,
  });
}

/** Give the requester a durable receipt for an online cancellation request. */
export async function sendSubscriptionCancellationRequestReceiptEmail(
  env: Env,
  request: SubscriptionCancellationRequestNotification,
): Promise<SmtpSendResult> {
  const frontend = (env.FRONTEND_URL || "https://herness.dots.net.tr").replace(/\/$/, "");
  const accountUrl = `${frontend}/dashboard`;
  const safeAccountUrl = escapeHtml(accountUrl);
  const effectLabel = cancellationEffectLabels[request.requestedEffect] || request.requestedEffect;

  return sendEmail(env, {
    to: request.requesterEmail,
    subject: `Abonelik iptal talebiniz alındı — ${request.id}`,
    replyTo: legalReplyTo(env),
    text: [
      "Abonelik iptal talebiniz alınmıştır.",
      "",
      `Talep kimliği: ${request.id}`,
      `Talep: ${effectLabel}`,
      `Alındı: ${request.receivedAt}`,
      `İşlem son tarihi: ${request.processingDueAt}`,
      request.refundDueAt ? `İade talebi son tarihi: ${request.refundDueAt}` : "İade talebi: Hayır",
      "",
      "Talebinizin durumu hesabınızdaki Planım bölümünden takip edilebilir. Bu alındı bildirimi, iptal veya iadenin onaylandığı anlamına gelmez; inceleme sonucu ayrıca bildirilir.",
      `Planım: ${accountUrl}`,
    ].join("\n"),
    html: `
      <p><strong>Abonelik iptal talebiniz alınmıştır.</strong></p>
      <ul>
        <li><strong>Talep kimliği:</strong> ${escapeHtml(request.id)}</li>
        <li><strong>Talep:</strong> ${escapeHtml(effectLabel)}</li>
        <li><strong>Alındı:</strong> ${escapeHtml(request.receivedAt)}</li>
        <li><strong>İşlem son tarihi:</strong> ${escapeHtml(request.processingDueAt)}</li>
        ${request.refundDueAt ? `<li><strong>İade talebi son tarihi:</strong> ${escapeHtml(request.refundDueAt)}</li>` : ""}
      </ul>
      <p>Talebinizin durumu hesabınızdaki Planım bölümünden takip edilebilir. Bu alındı bildirimi, iptal veya iadenin onaylandığı anlamına gelmez; inceleme sonucu ayrıca bildirilir.</p>
      <p><a href="${safeAccountUrl}">Planım bölümünü aç</a></p>
    `,
  });
}

export type SubscriptionCancellationDecisionNotification = {
  id: string;
  requesterEmail: string;
  requestedEffect: string;
  refundRequested: boolean;
  status: string;
  responseChannel: string;
  responseSummary: string;
  processedAt: string | null;
};

/** Send the operator's recorded cancellation/refund decision to the requester. */
export async function sendSubscriptionCancellationDecisionEmail(
  env: Env,
  decision: SubscriptionCancellationDecisionNotification,
): Promise<SmtpSendResult> {
  const frontend = (env.FRONTEND_URL || "https://herness.dots.net.tr").replace(/\/$/, "");
  const accountUrl = `${frontend}/dashboard`;
  const safeAccountUrl = escapeHtml(accountUrl);
  const effectLabel = cancellationEffectLabels[decision.requestedEffect] || decision.requestedEffect;
  const statusLabels: Record<string, string> = {
    accepted: "Kabul edildi",
    scheduled: "Dönem sonuna planlandı",
    completed: "Tamamlandı",
    rejected: "Reddedildi",
  };
  const statusLabel = statusLabels[decision.status] || decision.status;

  return sendEmail(env, {
    to: decision.requesterEmail,
    subject: `Abonelik iptal talebiniz sonuçlandı — ${decision.id}`,
    replyTo: legalReplyTo(env),
    text: [
      "Abonelik iptal/iade talebiniz hakkında karar kayda alınmıştır.",
      "",
      `Talep kimliği: ${decision.id}`,
      `Talep: ${effectLabel}`,
      `İade talebi: ${decision.refundRequested ? "Evet" : "Hayır"}`,
      `Durum: ${statusLabel}`,
      `Cevap kanalı: ${decision.responseChannel}`,
      decision.processedAt ? `Tamamlanma zamanı: ${decision.processedAt}` : "",
      "",
      "Karar / açıklama:",
      decision.responseSummary,
      "",
      `Planım: ${accountUrl}`,
    ].filter(Boolean).join("\n"),
    html: `
      <p><strong>Abonelik iptal/iade talebiniz hakkında karar kayda alınmıştır.</strong></p>
      <ul>
        <li><strong>Talep kimliği:</strong> ${escapeHtml(decision.id)}</li>
        <li><strong>Talep:</strong> ${escapeHtml(effectLabel)}</li>
        <li><strong>İade talebi:</strong> ${decision.refundRequested ? "Evet" : "Hayır"}</li>
        <li><strong>Durum:</strong> ${escapeHtml(statusLabel)}</li>
        <li><strong>Cevap kanalı:</strong> ${escapeHtml(decision.responseChannel)}</li>
        ${decision.processedAt ? `<li><strong>Tamamlanma zamanı:</strong> ${escapeHtml(decision.processedAt)}</li>` : ""}
      </ul>
      <p><strong>Karar / açıklama:</strong></p>
      <p style="white-space:pre-wrap">${escapeHtml(decision.responseSummary)}</p>
      <p><a href="${safeAccountUrl}">Planım bölümünü aç</a></p>
    `,
  });
}

function buildPasswordResetUrl(env: Env, email: string, token: string): string {
  const base = (env.FRONTEND_URL || "https://herness.dots.net.tr").replace(/\/$/, "");
  const params = new URLSearchParams({
    action: "reset-password",
    email,
    token,
  });
  return `${base}/login?${params.toString()}`;
}

export async function sendPasswordResetEmail(
  env: Env,
  email: string,
  token: string
): Promise<SmtpSendResult> {
  const resetUrl = buildPasswordResetUrl(env, email, token);
  const safeUrl = escapeHtml(resetUrl);
  const safeToken = escapeHtml(token);

  return sendEmail(env, {
    to: email,
    subject: "AI Watcher password reset",
    replyTo: legalReplyTo(env),
    text: [
      "AI Watcher hesabınız için şifre sıfırlama talebi aldık.",
      "",
      "Yeni şifre oluşturmak için bağlantıyı açın:",
      resetUrl,
      "",
      "Bağlantı çalışmazsa giriş ekranında aşağıdaki 6 haneli sıfırlama kodunu kullanın:",
      token,
      "",
      "Bu bağlantı ve kod 24 saat geçerlidir.",
      "Talebi siz yapmadıysanız bu e-postayı yok sayabilirsiniz.",
    ].join("\n"),
    html: `
      <p>AI Watcher hesabınız için şifre sıfırlama talebi aldık.</p>
      <p><a href="${safeUrl}">Şifremi sıfırla</a></p>
      <p>Bağlantı çalışmazsa giriş ekranında aşağıdaki 6 haneli kodu kullanın:</p>
      <p style="font-family:monospace;font-size:28px;letter-spacing:0.3em;font-weight:bold;">${safeToken}</p>
      <p>Bu bağlantı ve kod 24 saat geçerlidir.</p>
      <p>Talebi siz yapmadıysanız bu e-postayı yok sayabilirsiniz.</p>
    `,
  });
}

export async function sendEmailChangeNotificationEmail(
  env: Env,
  oldEmail: string,
  newEmail: string
): Promise<SmtpSendResult> {
  return sendEmail(env, {
    to: oldEmail,
    subject: "AI Watcher E-posta Değişikliği Bilgilendirmesi",
    replyTo: legalReplyTo(env),
    text: [
      "AI Watcher hesabınızın e-posta adresi güncellendi.",
      "",
      `Önceki e-posta: ${oldEmail}`,
      `Yeni e-posta: ${newEmail}`,
      "",
      "Eğer bu değişikliği siz yapmadıysanız lütfen acilen bizimle iletişime geçin.",
    ].join("\n"),
    html: `
      <p>AI Watcher hesabınızın e-posta adresi güncellendi.</p>
      <p><strong>Önceki e-posta:</strong> ${escapeHtml(oldEmail)}</p>
      <p><strong>Yeni e-posta:</strong> ${escapeHtml(newEmail)}</p>
      <p>Eğer bu değişikliği siz yapmadıysanız lütfen acilen bizimle iletişime geçin.</p>
    `,
  });
}

export type PaidOrderConfirmation = {
  merchantOid: string;
  customerEmail: string;
  customerName: string | null;
  customerPhone: string | null;
  customerAddress: string | null;
  planSlug: string;
  amountMinor: number;
  currency: string;
  kind: string;
  termsVersion: string | null;
  precontractVersion: string | null;
  distanceSalesVersion: string | null;
  refundVersion: string | null;
  subscriptionVersion: string | null;
  immediatePerformanceRequested: boolean;
  acceptedLocale: string | null;
  entitlementAvailableAt: string | null;
  entitlementStatus: string | null;
  entitlementActivatedAt: string | null;
};

/**
 * Durable order evidence for the consumer. The immutable archive URL is only
 * usable after the frontend legal publication gate has produced that archive.
 */
export async function sendPaidOrderConfirmationEmail(
  env: Env,
  order: PaidOrderConfirmation,
): Promise<SmtpSendResult> {
  const frontend = (env.FRONTEND_URL || "https://herness.dots.net.tr").replace(/\/$/, "");
  const archiveVersion = order.termsVersion?.trim() || "";
  if (!archiveVersion) throw new Error("legal_archive_version_missing");
  const archiveUrl = `${frontend}/legal-archive/${encodeURIComponent(archiveVersion)}.json`;
  const safeArchiveUrl = escapeHtml(archiveUrl);

  let archiveResponse: Response;
  try {
    archiveResponse = await fetch(archiveUrl, {
      headers: { Accept: "application/json", "Cache-Control": "no-cache" },
    });
  } catch {
    throw new Error("legal_archive_unreachable");
  }
  if (!archiveResponse.ok) throw new Error("legal_archive_unavailable");
  const archive = await archiveResponse.json().catch(() => null) as {
    archive_revision?: unknown;
    documents?: Record<string, Record<string, { lastUpdated?: unknown } | undefined> | undefined>;
  } | null;
  const archivedTurkishDocuments = archive?.documents?.tr;
  const requiredArchivedVersions: Record<string, string | null> = {
    terms: order.termsVersion,
    precontract: order.precontractVersion,
    distance_sales: order.distanceSalesVersion,
    refund: order.refundVersion,
    subscription: order.subscriptionVersion,
  };
  const archiveVersionsMatch = Object.entries(requiredArchivedVersions).every(
    ([documentKey, version]) => version && archivedTurkishDocuments?.[documentKey]?.lastUpdated === version,
  );
  if (archive?.archive_revision !== archiveVersion || !archivedTurkishDocuments || !archiveVersionsMatch) {
    throw new Error("legal_archive_invalid");
  }
  const amount = `${(order.amountMinor / 100).toFixed(2)} ${order.currency}`;
  const evidenceLines = [
    `Kullanım Koşulları: ${order.termsVersion || "kayıtlı değil"}`,
    `Ön Bilgilendirme Formu: ${order.precontractVersion || "kayıtlı değil"}`,
    `Mesafeli Satış Sözleşmesi: ${order.distanceSalesVersion || "kayıtlı değil"}`,
    `İptal/Cayma/İade Politikası: ${order.refundVersion || "kayıtlı değil"}`,
    `Abonelik Koşulları: ${order.subscriptionVersion || "kayıtlı değil"}`,
    `Hizmetin hemen başlatılması talebi: ${order.immediatePerformanceRequested ? "Evet" : "Hayır"}`,
    `Hizmet hakkı durumu: ${order.entitlementStatus || "kayıtlı değil"}`,
    `Hizmet hakkı kullanılabilirlik zamanı: ${order.entitlementAvailableAt || "kayıtlı değil"}`,
    `Hizmet hakkı etkinleşme zamanı: ${order.entitlementActivatedAt || "henüz etkinleşmedi"}`,
    `Onay dili: ${order.acceptedLocale || "tr"}`,
  ];
  const evidenceHtml = evidenceLines.map((line) => `<li>${escapeHtml(line)}</li>`).join("");

  return sendEmail(env, {
    to: order.customerEmail,
    subject: `AI Watcher sipariş onayı — ${order.merchantOid}`,
    replyTo: legalReplyTo(env),
    text: [
      "AI Watcher ödeme/sipariş onayınız",
      "",
      `Sipariş referansı: ${order.merchantOid}`,
      `Müşteri: ${order.customerName || "kayıtlı değil"}`,
      `Telefon: ${order.customerPhone || "kayıtlı değil"}`,
      `Adres: ${order.customerAddress || "kayıtlı değil"}`,
      `Plan: ${order.planSlug}`,
      `Tutar: ${amount}`,
      `İşlem türü: ${order.kind}`,
      "",
      "İşlem sırasında gösterilen hukuki belge sürümleri:",
      ...evidenceLines,
      "",
      `Belge arşivi: ${archiveUrl}`,
      "Bu e-posta sipariş ve hukuki belge kanıtıdır; fatura/e-Arşiv teslimi şirketin muhasebe süreci üzerinden ayrıca yapılmalıdır.",
    ].join("\n"),
    html: `
      <p><strong>AI Watcher ödeme/sipariş onayınız</strong></p>
      <p><strong>Sipariş referansı:</strong> ${escapeHtml(order.merchantOid)}<br />
      <strong>Müşteri:</strong> ${escapeHtml(order.customerName || "kayıtlı değil")}<br />
      <strong>Telefon:</strong> ${escapeHtml(order.customerPhone || "kayıtlı değil")}<br />
      <strong>Adres:</strong> ${escapeHtml(order.customerAddress || "kayıtlı değil")}<br />
      <strong>Plan:</strong> ${escapeHtml(order.planSlug)}<br />
      <strong>Tutar:</strong> ${escapeHtml(amount)}<br />
      <strong>İşlem türü:</strong> ${escapeHtml(order.kind)}</p>
      <p>İşlem sırasında gösterilen hukuki belge sürümleri:</p>
      <ul>${evidenceHtml}</ul>
      <p><a href="${safeArchiveUrl}">Değiştirilemez hukuki belge arşivini görüntüle</a></p>
      <p>Bu e-posta sipariş ve hukuki belge kanıtıdır; fatura/e-Arşiv teslimi şirketin muhasebe süreci üzerinden ayrıca yapılmalıdır.</p>
    `,
  });
}
