import type { Env } from "../env";

export type OutboundEmailMessage = {
  to: string;
  subject: string;
  text: string;
  html: string;
  replyTo?: string;
};

export type SmtpSendResult = {
  messageId: string;
};

function resolveFrom(env: Env): { email: string; name: string } {
  const email = (env.SMTP_FROM_EMAIL || env.SMTP_USERNAME || "").trim() || "herness@dots.net.tr";
  const name = (env.SMTP_FROM_NAME || "AI Watcher").trim();
  return { email, name };
}

// Resend HTTP API. Used when RESEND_API_KEY is set so transactional mail goes
// out through a high-reputation sender instead of the shared cPanel IP, which
// Gmail rejects with 550-5.7.1 "low reputation of the sending domain".
async function sendViaResend(env: Env, message: OutboundEmailMessage): Promise<SmtpSendResult> {
  const { email, name } = resolveFrom(env);
  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${env.RESEND_API_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      from: `${name} <${email}>`,
      to: [message.to],
      subject: message.subject,
      html: message.html,
      text: message.text,
      ...(message.replyTo ? { reply_to: message.replyTo } : {}),
    }),
  });
  if (!res.ok) {
    const detail = await res.text().catch(() => "");
    throw new Error(`Resend send failed (${res.status}): ${detail.slice(0, 300)}`);
  }
  const data = (await res.json().catch(() => ({}))) as { id?: string };
  return { messageId: data.id ? `<${data.id}@resend.dev>` : `<resend-${crypto.randomUUID()}@resend.dev>` };
}

/** Sends through Resend when configured, otherwise falls back to direct SMTP. */
export async function sendEmail(env: Env, message: OutboundEmailMessage): Promise<SmtpSendResult> {
  if ((env.RESEND_API_KEY || "").trim()) {
    return sendViaResend(env, message);
  }
  return sendSmtpEmail(env, message);
}

class SmtpLineReader {
  private readonly decoder = new TextDecoder();
  private buffer = "";

  constructor(private readonly reader: ReadableStreamDefaultReader<Uint8Array>) {}

  async readResponse(): Promise<{ code: number; lines: string[] }> {
    const lines: string[] = [];
    while (true) {
      const line = await this.readLine();
      lines.push(line);
      if (/^\d{3} /.test(line)) {
        return { code: Number.parseInt(line.slice(0, 3), 10), lines };
      }
    }
  }

  private async readLine(): Promise<string> {
    while (true) {
      const newlineIndex = this.buffer.indexOf("\n");
      if (newlineIndex >= 0) {
        const line = this.buffer.slice(0, newlineIndex + 1);
        this.buffer = this.buffer.slice(newlineIndex + 1);
        return line.replace(/\r?\n$/, "");
      }
      const { value, done } = await this.reader.read();
      if (done) throw new Error("SMTP connection closed unexpectedly");
      this.buffer += this.decoder.decode(value, { stream: true });
    }
  }
}

function encodeMimeHeader(value: string): string {
  if (/^[\x20-\x7E]*$/.test(value)) return value;
  const bytes = new TextEncoder().encode(value);
  const b64 = btoa(String.fromCharCode(...bytes));
  return `=?UTF-8?B?${b64}?=`;
}

function dotStuff(value: string): string {
  return value
    .replace(/\r?\n/g, "\r\n")
    .split("\r\n")
    .map((line) => (line.startsWith(".") ? `.${line}` : line))
    .join("\r\n");
}

function composeMimeMessage(env: Env, message: OutboundEmailMessage): { mime: string; messageId: string } {
  const boundary = `aiwatcher-boundary-${crypto.randomUUID()}`;
  const fromEmail =
    (env.SMTP_FROM_EMAIL || env.SMTP_USERNAME || "").trim() || "herness@dots.net.tr";
  const fromName = (env.SMTP_FROM_NAME || "AI Watcher").trim();
  const messageId = `<${crypto.randomUUID()}@dots.net.tr>`;
  const headers = [
    `From: ${encodeMimeHeader(fromName)} <${fromEmail}>`,
    `To: <${message.to}>`,
    `Subject: ${encodeMimeHeader(message.subject)}`,
    `Date: ${new Date().toUTCString()}`,
    `Message-ID: ${messageId}`,
    "MIME-Version: 1.0",
    `Content-Type: multipart/alternative; boundary="${boundary}"`,
  ];
  if (message.replyTo) {
    headers.push(`Reply-To: <${message.replyTo}>`);
  }

  const mime = [
    ...headers,
    "",
    `--${boundary}`,
    'Content-Type: text/plain; charset="UTF-8"',
    "Content-Transfer-Encoding: 8bit",
    "",
    message.text,
    "",
    `--${boundary}`,
    'Content-Type: text/html; charset="UTF-8"',
    "Content-Transfer-Encoding: 8bit",
    "",
    message.html,
    "",
    `--${boundary}--`,
    "",
  ].join("\r\n");

  return { mime, messageId };
}

async function expectCode(
  lineReader: SmtpLineReader,
  expectedCode: number,
  context: string
): Promise<void> {
  const response = await lineReader.readResponse();
  if (response.code !== expectedCode) {
    throw new Error(`SMTP ${context} failed (${response.code}): ${response.lines.join(" | ")}`);
  }
}

async function writeLine(
  writer: WritableStreamDefaultWriter<Uint8Array>,
  encoder: TextEncoder,
  value: string
): Promise<void> {
  await writer.write(encoder.encode(`${value}\r\n`));
}

export async function sendSmtpEmail(env: Env, message: OutboundEmailMessage): Promise<SmtpSendResult> {
  const host = (env.SMTP_HOST || "").trim();
  const port = Number.parseInt(String(env.SMTP_PORT || "465"), 10) || 465;
  const username = (env.SMTP_USERNAME || "").trim();
  const password = env.SMTP_PASSWORD || "";

  if (!host || !username || !password) {
    throw new Error("SMTP is not configured");
  }

  const { connect } = await import("cloudflare:sockets");
  const socket = connect({ hostname: host, port }, { secureTransport: "on", allowHalfOpen: false });
  const reader = socket.readable.getReader();
  const writer = socket.writable.getWriter();
  const lineReader = new SmtpLineReader(reader);
  const encoder = new TextEncoder();
  const { mime, messageId } = composeMimeMessage(env, message);

  try {
    await expectCode(lineReader, 220, "connect");
    await writeLine(writer, encoder, "EHLO dots.net.tr");
    const ehlo = await lineReader.readResponse();
    if (ehlo.code !== 250) throw new Error(`SMTP EHLO failed (${ehlo.code})`);

    const ehloText = ehlo.lines.join("\n").toUpperCase();
    if (ehloText.includes("AUTH PLAIN")) {
      const authPayload = btoa(`\u0000${username}\u0000${password}`);
      await writeLine(writer, encoder, `AUTH PLAIN ${authPayload}`);
      await expectCode(lineReader, 235, "auth plain");
    } else if (ehloText.includes("AUTH LOGIN")) {
      await writeLine(writer, encoder, "AUTH LOGIN");
      await expectCode(lineReader, 334, "auth login username prompt");
      await writeLine(writer, encoder, btoa(username));
      await expectCode(lineReader, 334, "auth login password prompt");
      await writeLine(writer, encoder, btoa(password));
      await expectCode(lineReader, 235, "auth login");
    } else {
      throw new Error("SMTP server does not advertise AUTH LOGIN/PLAIN");
    }

    const fromEmail =
      (env.SMTP_FROM_EMAIL || username || "").trim() || "herness@dots.net.tr";
    await writeLine(writer, encoder, `MAIL FROM:<${fromEmail}>`);
    await expectCode(lineReader, 250, "mail from");
    await writeLine(writer, encoder, `RCPT TO:<${message.to}>`);
    await expectCode(lineReader, 250, "rcpt to");
    await writeLine(writer, encoder, "DATA");
    await expectCode(lineReader, 354, "data");

    const mimeMessage = dotStuff(mime);
    await writer.write(encoder.encode(`${mimeMessage}\r\n.\r\n`));
    await expectCode(lineReader, 250, "send data");
    await writeLine(writer, encoder, "QUIT");
    await expectCode(lineReader, 221, "quit");
  } finally {
    try { await writer.close(); } catch {}
    try { await reader.cancel(); } catch {}
    try { await socket.close(); } catch {}
  }

  return { messageId };
}
