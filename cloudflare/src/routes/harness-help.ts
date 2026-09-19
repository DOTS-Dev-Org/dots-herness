import { Hono } from "hono";
import type { Context } from "hono";
import type { Env, AppVariables } from "../env";

type HelpLocale = "tr" | "en";

type HelpCopy = {
  otherLanguageName: string;
  otherLanguageCode: HelpLocale;
  eyebrow: string;
  title: string;
  lead: string;
  intro: string;
  boundaryTitle: string;
  boundaryBody: string;
  approvalTitle: string;
  approvalBody: string;
  modesTitle: string;
  modesIntro: string;
  modes: Array<{ name: string; description: string; tone: "quiet" | "accent" | "warning" }>;
  flowTitle: string;
  flow: Array<{ title: string; body: string }>;
  chooseTitle: string;
  chooseItems: string[];
  changeTitle: string;
  changeBody: string;
  noteTitle: string;
  noteBody: string;
  sourcePrefix: string;
  sourceLabel: string;
  sourceSuffix: string;
  footer: string;
};

const COPY: Record<HelpLocale, HelpCopy> = {
  tr: {
    otherLanguageName: "English",
    otherLanguageCode: "en",
    eyebrow: "DOTS Harness · Kontrol merkezi",
    title: "Erişim ve sandbox nasıl çalışır?",
    lead: "DOTS Harness’ın proje dosyalarına, terminale ve çalışma alanına nasıl eriştiğini tek bakışta anlayın.",
    intro: "Erişim seçimi iki ayrı şeyi birlikte açıklar: sandbox çalışma sınırı ve işlem onayı. Sandbox, ajanın nereye erişebileceğini; onay, ne zaman senden izin isteyeceğini belirler.",
    boundaryTitle: "Sandbox sınırı",
    boundaryBody: "Sandbox, DOTS Harness’ın çalıştığı alanı sınırlar. Proje dosyaları, terminal komutları ve bağlı araçlar bu sınır içinde yürür. Sınırın dışına çıkılması gereken bir işlem olursa işlem durur ve onay akışına geçer.",
    approvalTitle: "Onay politikası",
    approvalBody: "Onay politikası, güvenlik sınırından ayrı bir kullanıcı tercihidir. Bir işlemin sınır içinde yapılabilmesi, her zaman otomatik olarak yapılacağı anlamına gelmez; seçtiğin seviyeye göre DOTS Harness senden önce izin isteyebilir.",
    modesTitle: "Erişim seviyeleri",
    modesIntro: "Sohbet alanının altındaki erişim düğmesinden seçtiğin seviye, bir sonraki işlem akışının davranışını belirler.",
    modes: [
      { name: "Onay iste", description: "Proje dosyalarını kullanmadan veya komut çalıştırmadan önce her zaman sorar.", tone: "quiet" },
      { name: "Benim için onayla", description: "Yalnızca dosya yazmadan, komut çalıştırmadan veya simülatörü kullanmadan önce sorar.", tone: "accent" },
      { name: "Tam erişim", description: "Proje dosyalarına ve shell komutlarına geniş erişim verir; plan modunda komut çalıştırma da dahildir. Çalışma alanı verisini ağ üzerinden gönderebilecek hassas komutlar yine onay isteyebilir.", tone: "warning" },
    ],
    flowTitle: "Bir işlem olduğunda ne olur?",
    flow: [
      { title: "1 · İşlem hazırlanır", body: "DOTS Harness, isteğin için gereken dosya, komut veya araç erişimini belirler." },
      { title: "2 · Sınır kontrol edilir", body: "İşlem seçili sandbox ve çalışma alanı sınırı içinde mi diye kontrol edilir." },
      { title: "3 · Gerekirse sorulur", body: "Seçtiğin onay seviyesine göre işlem yürütülür ya da senden açık izin istenir." },
      { title: "4 · İşlem tamamlanır", body: "İzin verilen işlem seçili çalışma alanında yürütülür; izin verilmezse işlem başlamaz." },
    ],
    chooseTitle: "Hangi seviyeyi seçmeliyim?",
    chooseItems: [
      "Yeni veya hassas projelerde en dar erişim seviyesini kullanın.",
      "Çalışma alanını mümkün olduğunca belirli bir proje ya da worktree ile sınırlayın.",
      "Tam erişimi yalnızca görevin kapsamına ve çalıştırılacak komutlara güvendiğinizde seçin.",
    ],
    changeTitle: "Seçimi nereden değiştiririm?",
    changeBody: "Sohbet alanının altındaki erişim düğmesine tıklayın ve istediğiniz DOTS Harness seviyesini seçin. Değişiklik, sonraki işlem akışlarına uygulanır.",
    noteTitle: "Kısa not",
    noteBody: "Tam erişim, onay adımlarını azaltır ama erişim kapsamını genişletir. Güvenlik sınırı ve kullanıcı onayı birlikte çalışır; ikisini aynı şey olarak düşünmeyin.",
    sourcePrefix: "Genel sandbox ve onay yaklaşımını karşılaştırmak için",
    sourceLabel: "OpenAI dokümantasyonuna bakın",
    sourceSuffix: ".",
    footer: "DOTS Harness erişim modeli · Son güncelleme 19 Eylül 2026",
  },
  en: {
    otherLanguageName: "Türkçe",
    otherLanguageCode: "tr",
    eyebrow: "DOTS Harness · Control center",
    title: "How access and sandboxing work",
    lead: "Understand at a glance how DOTS Harness can access project files, the terminal, and your working area.",
    intro: "The access choice describes two separate controls together: the sandbox boundary and the approval policy. The sandbox defines where the agent can work; approvals define when it should ask you first.",
    boundaryTitle: "The sandbox boundary",
    boundaryBody: "The sandbox limits the area in which DOTS Harness can operate. Project files, shell commands, and connected tools run within that boundary. If an operation needs to go beyond it, the operation stops and enters the approval flow.",
    approvalTitle: "The approval policy",
    approvalBody: "The approval policy is a separate user preference from the security boundary. An operation being allowed inside the boundary does not always mean it runs automatically; DOTS Harness may ask first depending on the level you choose.",
    modesTitle: "Access levels",
    modesIntro: "The level selected from the access control below the composer determines how the next operation flow behaves.",
    modes: [
      { name: "Ask for approval", description: "Always asks before using project files or running commands.", tone: "quiet" },
      { name: "Approve for me", description: "Asks only before writing files, running commands, or using the simulator.", tone: "accent" },
      { name: "Full access", description: "Allows broad access to project files and shell commands, including commands in plan mode. Sensitive commands that could send working-area data over the network may still require approval.", tone: "warning" },
    ],
    flowTitle: "What happens when an operation starts?",
    flow: [
      { title: "1 · The operation is prepared", body: "DOTS Harness identifies the file, command, or tool access needed for your request." },
      { title: "2 · The boundary is checked", body: "The operation is checked against the selected sandbox and working-area boundary." },
      { title: "3 · Approval is requested if needed", body: "Depending on your approval level, the operation runs or you are asked for explicit permission." },
      { title: "4 · The operation completes", body: "An approved operation runs in the selected working area; if permission is denied, it does not start." },
    ],
    chooseTitle: "Which level should I choose?",
    chooseItems: [
      "Use the narrowest access level for new or sensitive projects.",
      "Keep the working area limited to a specific project or worktree whenever possible.",
      "Choose full access only when you trust the task scope and the commands that may run.",
    ],
    changeTitle: "Where can I change the selection?",
    changeBody: "Click the access control below the composer and choose the DOTS Harness level you want. The change applies to subsequent operation flows.",
    noteTitle: "A short note",
    noteBody: "Full access reduces approval steps but expands the access scope. The security boundary and user approval work together; they are not the same control.",
    sourcePrefix: "For the general sandbox and approval model, see the",
    sourceLabel: "OpenAI documentation",
    sourceSuffix: ".",
    footer: "DOTS Harness access model · Last updated September 19, 2026",
  },
};

function localeForRequest(request: Request): HelpLocale {
  const requested = new URL(request.url).searchParams.get("lang")?.toLowerCase() || "";
  if (requested === "tr" || requested.startsWith("tr-")) return "tr";
  if (requested === "en" || requested.startsWith("en-")) return "en";

  const accepted = request.headers.get("Accept-Language")?.toLowerCase() || "";
  return accepted.startsWith("tr") ? "tr" : "en";
}

function escapeHtml(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function renderList(items: string[]): string {
  return items.map((item) => `<li>${escapeHtml(item)}</li>`).join("");
}

function renderModes(copy: HelpCopy): string {
  return copy.modes.map((mode) => `
    <article class="mode-card ${mode.tone}">
      <div class="mode-icon" aria-hidden="true"></div>
      <h3>${escapeHtml(mode.name)}</h3>
      <p>${escapeHtml(mode.description)}</p>
    </article>`).join("");
}

function renderFlow(copy: HelpCopy): string {
  return copy.flow.map((step) => `
    <article class="flow-step">
      <h3>${escapeHtml(step.title)}</h3>
      <p>${escapeHtml(step.body)}</p>
    </article>`).join("");
}

function renderPage(locale: HelpLocale): string {
  const copy = COPY[locale];
  const languageURL = `/harness/sandboxing?lang=${copy.otherLanguageCode}`;
  return `<!doctype html>
<html lang="${locale}">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="description" content="${escapeHtml(copy.title)} — DOTS Harness">
    <title>${escapeHtml(copy.title)} · DOTS Harness</title>
    <style>
      :root {
        color-scheme: dark;
        --bg: #101112;
        --panel: #181a1c;
        --panel-soft: #202225;
        --line: #34373b;
        --text: #f1f2f3;
        --muted: #a4a7ab;
        --accent: #ff9f2d;
        --accent-soft: rgba(255, 159, 45, .13);
        --warning-soft: rgba(255, 104, 78, .12);
      }
      * { box-sizing: border-box; }
      html { background: var(--bg); }
      body {
        margin: 0;
        color: var(--text);
        background: radial-gradient(circle at 50% -10%, #292b2e 0, var(--bg) 38rem);
        font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", sans-serif;
        line-height: 1.55;
      }
      a { color: inherit; }
      .page { width: min(100% - 32px, 960px); margin: 0 auto; padding: 24px 0 64px; }
      .topbar { display: flex; align-items: center; justify-content: space-between; gap: 16px; margin-bottom: 72px; }
      .brand { font-size: 14px; font-weight: 700; letter-spacing: .04em; }
      .language { color: var(--muted); font-size: 13px; text-underline-offset: 4px; }
      .hero { max-width: 760px; margin-bottom: 56px; }
      .eyebrow { color: var(--accent); font-size: 13px; font-weight: 700; letter-spacing: .08em; text-transform: uppercase; }
      h1, h2, h3, p { margin-top: 0; }
      h1 { max-width: 680px; margin: 12px 0 18px; font-size: clamp(34px, 7vw, 62px); line-height: 1.02; letter-spacing: -.045em; }
      .lead { color: #d7d9db; max-width: 680px; font-size: clamp(18px, 2.7vw, 24px); line-height: 1.4; }
      .intro { color: var(--muted); max-width: 720px; margin: 22px 0 0; font-size: 16px; }
      .section { margin-top: 56px; }
      .section-heading { max-width: 680px; margin-bottom: 20px; }
      h2 { margin-bottom: 8px; font-size: 27px; letter-spacing: -.025em; }
      .section-heading p, .section-copy { color: var(--muted); }
      .two-up, .mode-grid, .flow-grid { display: grid; gap: 12px; }
      .two-up { grid-template-columns: repeat(2, minmax(0, 1fr)); }
      .mode-grid { grid-template-columns: repeat(3, minmax(0, 1fr)); }
      .flow-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); }
      .card, .mode-card, .flow-step, .note { border: 1px solid var(--line); border-radius: 18px; background: rgba(24, 26, 28, .86); }
      .card { padding: 24px; }
      .card h3 { font-size: 18px; margin-bottom: 8px; }
      .card p, .mode-card p, .flow-step p { color: var(--muted); margin-bottom: 0; font-size: 14px; }
      .mode-card { padding: 20px; min-height: 190px; }
      .mode-card.accent { border-color: rgba(255, 159, 45, .55); background: linear-gradient(145deg, var(--accent-soft), rgba(24, 26, 28, .92)); }
      .mode-card.warning { border-color: rgba(255, 104, 78, .4); background: linear-gradient(145deg, var(--warning-soft), rgba(24, 26, 28, .92)); }
      .mode-icon { width: 11px; height: 11px; margin-bottom: 22px; border-radius: 50%; background: #9da1a6; box-shadow: 0 0 0 5px rgba(157, 161, 166, .1); }
      .accent .mode-icon { background: var(--accent); box-shadow: 0 0 0 5px var(--accent-soft); }
      .warning .mode-icon { background: #ff684e; box-shadow: 0 0 0 5px var(--warning-soft); }
      .mode-card h3 { margin-bottom: 8px; font-size: 18px; }
      .flow-step { padding: 20px; }
      .flow-step h3 { font-size: 16px; margin-bottom: 7px; }
      .choice-list { margin: 0; padding: 0; list-style: none; }
      .choice-list li { position: relative; padding: 0 0 13px 26px; color: #d7d9db; }
      .choice-list li:last-child { padding-bottom: 0; }
      .choice-list li::before { content: ""; position: absolute; left: 3px; top: .65em; width: 8px; height: 8px; border-radius: 50%; background: var(--accent); }
      .note { padding: 22px 24px; border-color: rgba(255, 159, 45, .35); background: var(--accent-soft); }
      .note h2 { font-size: 20px; }
      .note p { margin-bottom: 0; color: #ded4c8; }
      .change { padding: 22px 0 0; }
      .change p { color: var(--muted); max-width: 700px; }
      .source { margin-top: 56px; padding-top: 22px; border-top: 1px solid var(--line); color: var(--muted); font-size: 13px; }
      .source a { color: #d7d9db; text-underline-offset: 4px; }
      footer { margin-top: 34px; color: #777b80; font-size: 12px; }
      @media (max-width: 700px) {
        .page { width: min(100% - 24px, 600px); padding-top: 18px; }
        .topbar { margin-bottom: 54px; }
        .two-up, .mode-grid, .flow-grid { grid-template-columns: 1fr; }
        .mode-card { min-height: auto; }
        .section { margin-top: 44px; }
      }
    </style>
  </head>
  <body>
    <main class="page">
      <nav class="topbar" aria-label="DOTS Harness">
        <div class="brand">DOTS Harness</div>
        <a class="language" href="${languageURL}">${escapeHtml(copy.otherLanguageName)}</a>
      </nav>

      <header class="hero">
        <div class="eyebrow">${escapeHtml(copy.eyebrow)}</div>
        <h1>${escapeHtml(copy.title)}</h1>
        <p class="lead">${escapeHtml(copy.lead)}</p>
        <p class="intro">${escapeHtml(copy.intro)}</p>
      </header>

      <section class="section" aria-labelledby="controls-title">
        <div class="two-up">
          <article class="card">
            <h3 id="controls-title">${escapeHtml(copy.boundaryTitle)}</h3>
            <p>${escapeHtml(copy.boundaryBody)}</p>
          </article>
          <article class="card">
            <h3>${escapeHtml(copy.approvalTitle)}</h3>
            <p>${escapeHtml(copy.approvalBody)}</p>
          </article>
        </div>
      </section>

      <section class="section" aria-labelledby="modes-title">
        <div class="section-heading">
          <h2 id="modes-title">${escapeHtml(copy.modesTitle)}</h2>
          <p>${escapeHtml(copy.modesIntro)}</p>
        </div>
        <div class="mode-grid">${renderModes(copy)}</div>
      </section>

      <section class="section" aria-labelledby="flow-title">
        <div class="section-heading">
          <h2 id="flow-title">${escapeHtml(copy.flowTitle)}</h2>
        </div>
        <div class="flow-grid">${renderFlow(copy)}</div>
      </section>

      <section class="section" aria-labelledby="choose-title">
        <div class="two-up">
          <article class="card">
            <h2 id="choose-title">${escapeHtml(copy.chooseTitle)}</h2>
            <ul class="choice-list">${renderList(copy.chooseItems)}</ul>
          </article>
          <article class="card change">
            <h2>${escapeHtml(copy.changeTitle)}</h2>
            <p>${escapeHtml(copy.changeBody)}</p>
          </article>
        </div>
      </section>

      <section class="section note" aria-labelledby="note-title">
        <h2 id="note-title">${escapeHtml(copy.noteTitle)}</h2>
        <p>${escapeHtml(copy.noteBody)}</p>
      </section>

      <p class="source">${escapeHtml(copy.sourcePrefix)} <a href="https://learn.chatgpt.com/docs/sandboxing?surface=app#how-you-control-it" rel="noreferrer">${escapeHtml(copy.sourceLabel)}</a>${escapeHtml(copy.sourceSuffix)}</p>
      <footer>${escapeHtml(copy.footer)}</footer>
    </main>
  </body>
</html>`;
}

const harnessHelp = new Hono<{ Bindings: Env; Variables: AppVariables }>();

function serveHelpPage(c: Context<{ Bindings: Env; Variables: AppVariables }>) {
  const locale = localeForRequest(c.req.raw);
  c.header("Cache-Control", "public, max-age=300, s-maxage=300");
  return c.html(renderPage(locale));
}

harnessHelp.get("/sandboxing", serveHelpPage);
harnessHelp.get("/sandboxing/", serveHelpPage);

export { harnessHelp };
