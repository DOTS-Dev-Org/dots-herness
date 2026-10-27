---
id: promo-video
name: Promo Video (Vertical Reel)
description: Make a vertical 9:16 promotional video for the current project from code - HTML/CSS scenes, headless browser frame capture, FFmpeg, synthesized music. Use when the user asks for a promo, intro, teaser, reel or social-media video of their project.
---

# Promo Video (Vertical Reel)

Produces a 1080x1920, 30 fps, about 20 second H.264/AAC MP4 that explains the user's project, ready for Reels / TikTok / Shorts. Everything is rendered locally from three small files. Nothing is installed and no account or API key is used.

How it works: the video is one HTML page whose CSS animations are laid out on an absolute timeline. A Node script drives a headless Chromium browser over the DevTools protocol, pauses every animation, sets its time for each frame, screenshots it, and pipes the frames into FFmpeg together with a score synthesized by a stdlib Python script.

## 0. Check the tools first

Needs: Node 22+ (built-in `fetch` and `WebSocket`), a Chromium browser (Chrome, Edge or Chromium), `ffmpeg`, and Python 3. Check each with a version command. If one is missing, tell the user which one and stop - do not install anything unless they ask. Desktop only: this cannot run on iOS or Android.

## 1. Understand the project before writing a word

The video is only as good as this step. Read, do not guess.

- Read the README, docs, manifest files and the main entry points. Work out what the product is, who it is for, and the three or four things it really does.
- Every claim on screen must trace to something in the workspace. Count numbers from the source (supported platforms, integrations, languages, tests) and remember where each came from. No invented metrics, users, awards or quotes.
- Find the brand: logo or mascot file, the colors the app itself uses, the product name exactly as written. Find the public URL in config; if there is none, leave the URL out.
- Do not use third-party logos. Name other products in plain text only.
- If the workspace does not make the product clear, ask the user one short question instead of inventing a pitch.

## 2. Storyboard

Write the copy in the language the user is speaking. Six scenes, cut on the beat (120 BPM, one beat = 0.5 s):

| Time | Scene | Content |
|---|---|---|
| 0-3 s | Hook | Logo or mascot pops in, product name, one-line promise |
| 3-7 s | Breadth | The biggest number or range, with a moving strip of chips |
| 7-11.5 s | In action | A drawn mock of the product doing its main job, step by step |
| 11.5-14.5 s | Second strength | Three cards that complete one after another |
| 14.5-17.5 s | Reach | Where it runs or who it is for, as big pills |
| 17.5-20 s | End card | Logo, name, tagline, URL button, maker |

Rules: one idea per scene. Headline of at most five words on two lines, one word group in the accent color. A small upper-case kicker above it. At most one supporting line. If a scene needs more words, it is two scenes. Drop or merge scenes the project cannot honestly fill.

## 3. Build the page

Create `output/<product>-reel-<yyyy-mm-dd>/` in the workspace and write the three files below into it. Do not overwrite an existing folder. Then edit `index.html`:

- Keep the mechanics exactly: every `animation-delay` is an absolute time in seconds on the timeline (`--in`/`--out` on a scene, `--d` on an element, `--a`/`--b` for things that switch on and off), and the `seek()` function at the bottom. Never add JavaScript-driven or time-of-day animation; a frame must depend only on `seek(t)`.
- Replace the palette in `:root` with the product's own colors: a dark background, a light text color, one accent, one secondary accent. Keep text contrast high.
- Replace all copy, the chips, the window mock contents, the cards and the pills with this project's content. Point the image `src` at the real logo with a path relative to the reel folder.
- Keep the safe area: the scene padding of 250px top and 400px bottom stays clear of the platform's interface. Keep body text at 38px or larger.
- Mock interfaces are drawn, never screenshots with private content. Use neutral sample data.
- If the length changes, change `SECONDS` in `render.mjs` and the scene times together.

## 4. Check stills, then render

Never render the full video blind. From the reel folder:

```sh
node render.mjs 2 5.5 9 13.8 16.6 19.5
```

This writes `still-<t>.png` for those seconds. Look at every still: text clipped or overflowing, empty halves, unreadable contrast, a wrong tab or card state, a missing image. Fix and repeat until each scene is clean. Then:

```sh
node render.mjs
```

A 20 second video takes about two minutes. Afterwards confirm with `ffprobe` that the file is 1080x1920 with a video and an audio stream of the expected duration, pull three or four frames from the MP4 and look at them, then delete the stills and `music.wav`.

If the browser cannot start inside the command sandbox, say so and let the user decide; do not disable sandboxing on your own.

## 5. Report

Give the path to the MP4 and say plainly: the scene list, where each number came from, that mock interfaces are drawings, that the music is synthesized and you could not listen to it, and which command re-renders after an edit.

## File: index.html

A complete, tested example (the HerNess reel). Keep the structure and the CSS classes; replace the content.

```html
<!doctype html>
<html lang="tr">
<meta charset="utf-8">
<title>HerNess reel</title>
<style>
/* Every animation-delay is an absolute time on the 20s timeline; render.mjs
   pauses all animations and sets currentTime per frame. */
:root { --ink:#15100c; --ink2:#221912; --line:#3a2c20; --cream:#fff3e3; --mute:#b9a48e;
        --orange:#ff7a1a; --yolk:#ffc857; --green:#5fd38d; --red:#ff6b5e; }
* { box-sizing:border-box; margin:0; }
html,body { width:1080px; height:1920px; overflow:hidden; background:var(--ink); }
body { font-family:-apple-system,"SF Pro Display","Helvetica Neue",sans-serif; color:var(--cream);
       -webkit-font-smoothing:antialiased; }
.mono { font-family:"SF Mono",Menlo,monospace; }

.bg { position:absolute; inset:0;
      background:radial-gradient(circle,#4a3523 2.5px,transparent 3px) 0 0/54px 54px; opacity:.55; }
.glow { position:absolute; width:1500px; height:1500px; border-radius:50%; left:-210px; top:140px;
        background:radial-gradient(circle,rgba(255,122,26,.34),rgba(255,122,26,0) 62%);
        animation:drift 20s linear both; }
@keyframes drift { from { transform:translate(-140px,-260px) scale(1); } to { transform:translate(160px,420px) scale(1.25); } }

.scene { position:absolute; inset:0; padding:250px 70px 400px; display:flex; flex-direction:column; justify-content:center;
         opacity:0; animation:sIn .35s ease-out both var(--in), sOut .3s ease-in forwards var(--out); }
@keyframes sIn { from { opacity:0; } to { opacity:1; } }
@keyframes sOut { from { opacity:1; transform:scale(1); } to { opacity:0; transform:scale(1.04); } }
.center { align-items:center; justify-content:center; text-align:center; }

.rise { animation:rise .55s cubic-bezier(.2,.9,.2,1) both var(--d); }
@keyframes rise { from { opacity:0; transform:translateY(70px); } to { opacity:1; transform:none; } }
.pop { animation:pop .5s cubic-bezier(.3,1.6,.5,1) both var(--d); }
@keyframes pop { from { opacity:0; transform:scale(.4); } to { opacity:1; transform:none; } }

h1 { font-size:124px; line-height:1.02; font-weight:800; letter-spacing:-4px; }
h1 em { font-style:normal; color:var(--orange); }
.kicker { font-size:34px; font-weight:700; letter-spacing:6px; color:var(--yolk); margin-bottom:28px; }
.sub { font-size:46px; font-weight:500; color:var(--mute); margin-top:30px; line-height:1.25; }

/* 1 + 6: brand */
.mascot { width:560px; height:560px; filter:drop-shadow(0 30px 60px rgba(0,0,0,.55)); }
.bob { animation:bob 1s ease-in-out infinite; }
@keyframes bob { 50% { transform:translateY(-16px) rotate(-2deg); } }
.word { font-size:176px; font-weight:800; letter-spacing:-7px; margin-top:10px; }
.word b { color:var(--orange); }

/* 2: providers */
.rows { margin:70px -70px 0; display:flex; flex-direction:column; gap:26px; }
.row { display:flex; gap:22px; white-space:nowrap; animation:slideL 4.6s linear both 2.9s; }
.row:nth-child(even) { animation-name:slideR; }
@keyframes slideL { from { transform:translateX(40px); } to { transform:translateX(-420px); } }
@keyframes slideR { from { transform:translateX(-460px); } to { transform:translateX(0); } }
.chip { font-size:40px; font-weight:650; padding:22px 38px; border-radius:60px;
        background:var(--ink2); border:2px solid var(--line); }
.chip.hot { background:var(--orange); border-color:var(--orange); color:var(--ink); }

/* 3: workspace */
.win { margin-top:56px; height:900px; border-radius:34px; background:#1b140e; border:2px solid var(--line);
       box-shadow:0 50px 110px rgba(0,0,0,.6); overflow:hidden; display:flex; flex-direction:column; }
.bar { height:62px; display:flex; align-items:center; gap:12px; padding:0 26px; border-bottom:2px solid var(--line); }
.bar i { width:18px; height:18px; border-radius:50%; background:#5b4634; }
.bar span { margin-left:16px; font-size:24px; color:var(--mute); }
.top { display:flex; height:350px; border-bottom:2px solid var(--line); }
.side { width:230px; padding:24px 20px; border-right:2px solid var(--line); font-size:24px; color:var(--mute);
        display:flex; flex-direction:column; gap:16px; }
.side b { color:var(--cream); background:var(--ink2); padding:10px 14px; border-radius:12px; margin:-10px -14px; }
.chat { flex:1; padding:24px 28px; display:flex; flex-direction:column; gap:16px; font-size:27px; }
.me { align-self:flex-end; background:var(--orange); color:var(--ink); font-weight:650; padding:14px 22px; border-radius:22px 22px 6px 22px; }
.step { color:var(--mute); } .step b { color:var(--cream); font-weight:500; } .ok { color:var(--green); font-weight:650; }
.tabs { display:flex; gap:10px; padding:18px 22px 0; }
.tab { position:relative; font-size:27px; font-weight:650; padding:12px 24px; border-radius:14px; color:var(--mute); }
.tab::before { content:""; position:absolute; inset:0; border-radius:14px; background:var(--orange); opacity:0; z-index:-1;
               animation:on .15s both var(--a), off .15s forwards var(--b); }
.tab span { animation:ink .15s both var(--a), unink .15s forwards var(--b); }
@keyframes on { to { opacity:1; } } @keyframes off { to { opacity:0; } }
@keyframes ink { to { color:var(--ink); } } @keyframes unink { to { color:var(--mute); } }
.panels { position:relative; flex:1; }
.panel { position:absolute; inset:22px 26px; font-size:27px; line-height:1.75; opacity:0;
         animation:pIn .2s both var(--a), off .15s forwards var(--b); }
@keyframes pIn { from { opacity:0; transform:translateY(18px); } to { opacity:1; transform:none; } }
.add,.del { display:block; padding:0 14px; border-radius:8px; }
.add { background:rgba(95,211,141,.16); color:var(--green); } .del { background:rgba(255,107,94,.16); color:var(--red); }
.addr { background:var(--ink2); border-radius:40px; padding:6px 24px; color:var(--mute); margin-bottom:18px; }
.sk { height:46px; border-radius:12px; background:var(--ink2); margin-bottom:16px; }

/* 4: tasks */
.tasks { margin-top:64px; display:flex; flex-direction:column; gap:26px; }
.task { display:flex; align-items:center; gap:28px; padding:44px 40px; border-radius:34px;
        background:var(--ink2); border:2px solid var(--line); }
.task .when { font-size:32px; color:var(--yolk); font-weight:650; letter-spacing:1px; }
.task .what { font-size:58px; font-weight:700; margin-top:6px; }
.check { margin-left:auto; width:84px; height:84px; border-radius:50%; background:var(--green); color:var(--ink);
         font-size:54px; font-weight:800; display:grid; place-items:center; }
.note { margin-top:50px; font-size:42px; color:var(--mute); }
.note b { color:var(--cream); }

/* 5: platforms */
.plats { margin-top:70px; display:flex; flex-wrap:wrap; gap:26px; }
.plat { font-size:84px; font-weight:750; padding:36px 58px; border-radius:30px; background:var(--ink2); border:2px solid var(--line); }
.plat.hot { background:var(--yolk); border-color:var(--yolk); color:var(--ink); }

.cta { margin-top:54px; font-size:44px; font-weight:700; padding:24px 50px; border-radius:60px;
       background:var(--orange); color:var(--ink); }
.dots { margin-top:34px; font-size:30px; letter-spacing:12px; color:var(--mute); font-weight:700; }
</style>

<div class="bg"></div><div class="glow"></div>

<!-- 1 · 0–3s -->
<section class="scene center" style="--in:0s;--out:2.75s">
  <img class="mascot pop" style="--d:.1s" src="../../shared/branding/herness-logo.webp">
  <div class="word rise" style="--d:.6s">Her<b>Ness</b></div>
  <div class="sub rise" style="--d:1.1s">Yapay zekâ çalışma alanın.</div>
</section>

<!-- 2 · 3–7s -->
<section class="scene" style="--in:3s;--out:6.75s">
  <div class="kicker rise" style="--d:3.05s">MODEL ÖZGÜRLÜĞÜ</div>
  <h1 class="rise" style="--d:3.15s"><em>30</em> sağlayıcı.<br>Tek uygulama.</h1>
  <div class="rows rise" style="--d:3.6s">
    <div class="row"><span class="chip">Anthropic</span><span class="chip hot">OpenAI</span><span class="chip">Gemini</span><span class="chip">Mistral</span><span class="chip">DeepSeek</span><span class="chip">Groq</span><span class="chip">Cohere</span></div>
    <div class="row"><span class="chip">Perplexity</span><span class="chip">Qwen</span><span class="chip">OpenRouter</span><span class="chip hot">Grok</span><span class="chip">Kimi</span><span class="chip">Cerebras</span><span class="chip">NVIDIA</span><span class="chip">MiniMax</span></div>
    <div class="row"><span class="chip">Fireworks</span><span class="chip">Together AI</span><span class="chip hot">Anthropic</span><span class="chip">Nebius</span><span class="chip">Z.ai</span><span class="chip">DeepInfra</span><span class="chip">Hyperbolic</span></div>
    <div class="row"><span class="chip">SiliconFlow</span><span class="chip">Chutes</span><span class="chip">GitHub</span><span class="chip">Google Cloud</span><span class="chip hot">Gemini</span><span class="chip">OpenCode</span><span class="chip">iFlow</span></div>
  </div>
  <div class="sub rise" style="--d:4.5s">İşe göre modeli sen seç.</div>
</section>

<!-- 3 · 7–11.5s -->
<section class="scene" style="--in:7s;--out:11.25s">
  <div class="kicker rise" style="--d:7.05s">PROJE ÖNCELİKLİ</div>
  <h1 class="rise" style="--d:7.15s">Oku. Çalıştır.<br><em>İncele.</em></h1>
  <div class="win rise" style="--d:7.5s">
    <div class="bar"><i></i><i></i><i></i><span>HerNess — web-app</span></div>
    <div class="top">
      <div class="side"><span>Projeler</span><b>web-app</b><span>mobile</span><span>api</span><span>Zamanlanmış</span><span>Eklentiler</span></div>
      <div class="chat">
        <div class="me rise" style="--d:7.9s">Giriş hatasını düzelt</div>
        <div class="step mono rise" style="--d:8.4s">▸ <b>read_file</b> auth.ts</div>
        <div class="step mono rise" style="--d:8.9s">▸ <b>edit_file</b> auth.ts</div>
        <div class="step mono rise" style="--d:9.4s">▸ <b>run_command</b> npm test</div>
        <div class="ok rise" style="--d:10s">✓ 42 test geçti</div>
      </div>
    </div>
    <div class="tabs">
      <div class="tab" style="--a:8s;--b:8.85s"><span style="--a:8s;--b:8.85s">Review</span></div>
      <div class="tab" style="--a:8.85s;--b:9.7s"><span style="--a:8.85s;--b:9.7s">Terminal</span></div>
      <div class="tab" style="--a:9.7s;--b:10.5s"><span style="--a:9.7s;--b:10.5s">Files</span></div>
      <div class="tab" style="--a:10.5s;--b:99s"><span style="--a:10.5s;--b:99s">Browser</span></div>
    </div>
    <div class="panels mono">
      <div class="panel" style="--a:8s;--b:8.85s">auth.ts<span class="del">- if (token.exp &lt; now)</span><span class="add">+ if (token.exp &lt;= now)</span><span class="add">+   return refresh(token)</span></div>
      <div class="panel" style="--a:8.85s;--b:9.7s">$ npm test<br><span class="ok">PASS</span> auth.test.ts<br><span class="ok">PASS</span> session.test.ts<br>Tests: 42 passed</div>
      <div class="panel" style="--a:9.7s;--b:10.5s">▾ src<br>&nbsp;&nbsp;▸ components<br>&nbsp;&nbsp;● auth.ts<br>&nbsp;&nbsp;○ session.ts</div>
      <div class="panel" style="--a:10.5s;--b:99s"><div class="addr">localhost:3000/login</div><div class="sk" style="width:60%"></div><div class="sk"></div><div class="sk" style="width:40%;background:var(--orange)"></div></div>
    </div>
  </div>
</section>

<!-- 4 · 11.5–14.5s -->
<section class="scene" style="--in:11.5s;--out:14.25s">
  <div class="kicker rise" style="--d:11.55s">ZAMANLANMIŞ GÖREVLER</div>
  <h1 class="rise" style="--d:11.65s">Sen planla.<br><em>O çalışsın.</em></h1>
  <div class="tasks">
    <div class="task rise" style="--d:12s"><div><div class="when">HER GÜN · 09:00</div><div class="what">Günlük özet</div></div><div class="check pop" style="--d:12.5s">✓</div></div>
    <div class="task rise" style="--d:12.25s"><div><div class="when">HER PAZARTESİ</div><div class="what">PR incelemesi</div></div><div class="check pop" style="--d:13s">✓</div></div>
    <div class="task rise" style="--d:12.5s"><div><div class="when">HER SAAT</div><div class="what">E-posta takibi</div></div><div class="check pop" style="--d:13.5s">✓</div></div>
  </div>
  <div class="note rise" style="--d:13s">Komutlar <b>sandbox</b> içinde, <b>senin onayınla</b>.</div>
</section>

<!-- 5 · 14.5–17.5s -->
<section class="scene" style="--in:14.5s;--out:17.25s">
  <div class="kicker rise" style="--d:14.55s">YEREL UYGULAMA</div>
  <h1 class="rise" style="--d:14.65s">Her cihazda.<br><em>29 dilde.</em></h1>
  <div class="plats">
    <div class="plat pop" style="--d:15s">macOS</div><div class="plat pop" style="--d:15.25s">Windows</div>
    <div class="plat pop" style="--d:15.5s">Linux</div><div class="plat pop" style="--d:15.75s">iOS</div>
    <div class="plat pop hot" style="--d:16s">Android</div>
  </div>
  <div class="sub rise" style="--d:16.2s">Eklentiler, MCP ve tarayıcı dahil.</div>
</section>

<!-- 6 · 17.5–20s -->
<section class="scene center" style="--in:17.5s;--out:99s">
  <div class="pop" style="--d:17.55s"><img class="mascot bob" style="width:440px;height:440px" src="../../shared/branding/herness-logo.webp"></div>
  <div class="word rise" style="--d:17.8s">Her<b>Ness</b></div>
  <div class="sub rise" style="--d:18.1s">Fikrinden çalışan çözüme.</div>
  <div class="cta pop" style="--d:18.5s">herness.dots.net.tr</div>
  <div class="dots rise" style="--d:18.8s">DOTS</div>
</section>

<script>
function seek(t) {
  for (const a of document.getAnimations()) { a.pause(); a.currentTime = t * 1000; }
  return new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));
}
</script>
</html>
```

## File: render.mjs

Change `SECONDS` and `OUT` at the top; leave the rest.

```js
#!/usr/bin/env node
// Render index.html to herness-reel.mp4: headless Chrome over CDP -> ffmpeg.
// Needs only Node 22+, a Chromium browser, ffmpeg and python. Usage: node render.mjs [stillSeconds...]
// Stills (still-<t>.png) are for checking layout before the full render.
import { spawn, execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const FPS = 30, SECONDS = 20, PORT = 9339, OUT = "herness-reel.mp4";
const stills = process.argv.slice(2).map(Number);

const browser = [process.env.CHROME,
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
  "/Applications/Chromium.app/Contents/MacOS/Chromium",
  "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe",
  "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe",
  "/usr/bin/google-chrome", "/usr/bin/chromium", "/usr/bin/chromium-browser",
].find(p => p && existsSync(p));
if (!browser) throw new Error("No Chromium browser found. Set CHROME to its executable path.");

const chrome = spawn(browser, [
  "--headless=new", `--remote-debugging-port=${PORT}`, `--user-data-dir=${mkdtempSync(join(tmpdir(), "reel-"))}`,
  "--hide-scrollbars", "--allow-file-access-from-files", "--window-size=1080,1920", "about:blank",
], { stdio: "ignore" });

let target;
for (let i = 0; !target; i++) {
  await new Promise(r => setTimeout(r, 250));
  try { target = (await (await fetch(`http://127.0.0.1:${PORT}/json`)).json()).find(t => t.type === "page"); }
  catch (e) { if (i > 40) throw e; }
}
const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise(r => ws.onopen = r);
let id = 0; const pending = new Map();
ws.onmessage = m => { const d = JSON.parse(m.data); pending.get(d.id)?.(d.result); pending.delete(d.id); };
const cdp = (method, params = {}) => new Promise(r => { pending.set(++id, r); ws.send(JSON.stringify({ id, method, params })); });

await cdp("Emulation.setDeviceMetricsOverride", { width: 1080, height: 1920, deviceScaleFactor: 1, mobile: false });
await cdp("Page.navigate", { url: pathToFileURL(join(here, "index.html")).href });
await cdp("Runtime.evaluate", { expression: "new Promise(r => document.readyState === 'complete' ? r() : addEventListener('load', r)).then(() => Promise.all([...document.images].map(i => i.decode())))", awaitPromise: true });
const frame = async t => {
  await cdp("Runtime.evaluate", { expression: `seek(${t})`, awaitPromise: true });
  return Buffer.from((await cdp("Page.captureScreenshot", { format: "png" })).data, "base64");
};

if (stills.length) {
  for (const t of stills) writeFileSync(join(here, `still-${t}.png`), await frame(t));
} else {
  execFileSync(process.platform === "win32" ? "python" : "python3", [join(here, "music.py"), join(here, "music.wav"), String(SECONDS)]);
  const ff = spawn("ffmpeg", ["-v", "error", "-y", "-f", "image2pipe", "-framerate", FPS, "-c:v", "png", "-i", "-",
    "-i", join(here, "music.wav"), "-af", "loudnorm=I=-14:TP=-1.5", "-c:v", "libx264", "-preset", "slow", "-crf", "16",
    "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k", "-ar", "48000", "-shortest", "-movflags", "+faststart",
    join(here, OUT)], { stdio: ["pipe", "inherit", "inherit"] });
  for (let f = 0; f < FPS * SECONDS; f++) {
    if (!ff.stdin.write(await frame(f / FPS))) await new Promise(r => ff.stdin.once("drain", r));
  }
  ff.stdin.end();
  await new Promise(r => ff.on("close", r));
}
ws.close(); chrome.kill();
```

## File: music.py

Change `CHORDS` for a different mood (the default is Am F C G). Keep 120 BPM unless the scene times change with it.

```python
#!/usr/bin/env python3
"""Synthesize the 120 BPM score for the reel. Stdlib only. Usage: music.py out.wav [seconds]"""
import math, random, struct, sys, wave

SR, BPM = 44100, 120
SECONDS = int(sys.argv[2]) if len(sys.argv) > 2 else 20
BEAT = 60 / BPM
N = SR * SECONDS
# Am F C G, one bar each
CHORDS = [(220.0, 261.63, 329.63), (174.61, 220.0, 261.63), (261.63, 329.63, 392.0), (196.0, 246.94, 293.66)]
random.seed(7)
out = [0.0] * N
TAU = 2 * math.pi

for i in range(N):
    t = i / SR
    beat = t / BEAT
    bar = int(beat // 4)
    chord = CHORDS[bar % 4]
    bt = (beat % 1) * BEAT              # time since last beat
    duck = min(1.0, bt / 0.18) if bar >= 1 else 1.0   # sidechain
    s = 0.0
    # pad
    for f in chord:
        s += 0.05 * duck * (math.sin(TAU * f * t) + math.sin(TAU * f * 1.006 * t))
    # bass, eighth notes
    et = (beat * 2 % 1) * BEAT / 2
    fb = chord[0] / 2
    s += 0.22 * duck * math.exp(-et * 7) * math.tanh(2.5 * math.sin(TAU * fb * t))
    # arp, sixteenths, from bar 2
    if bar >= 2:
        step = int(beat * 4)
        st = (beat * 4 % 1) * BEAT / 4
        fa = chord[step % 3] * (2 if step % 4 < 2 else 4)
        s += 0.09 * math.exp(-st * 22) * math.sin(TAU * fa * t)
    if bar >= 1:
        # kick: pitch sweep 130 -> 45 Hz
        s += 0.75 * math.exp(-bt * 9) * math.sin(TAU * (45 * bt + 85 / 28 * (1 - math.exp(-bt * 28))))
        # offbeat hat
        ht = ((beat + 0.5) % 1) * BEAT
        s += 0.07 * math.exp(-ht * 70) * random.uniform(-1, 1)
    out[i] = s * min(1.0, t / 0.05, (SECONDS - t) / 1.2)

peak = max(abs(x) for x in out)
with wave.open(sys.argv[1], "wb") as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
    w.writeframes(struct.pack(f"<{N}h", *(int(x / peak * 30000) for x in out)))
```
