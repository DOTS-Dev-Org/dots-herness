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
