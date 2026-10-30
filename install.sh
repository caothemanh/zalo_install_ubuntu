#!/usr/bin/env bash
# Zalo Backup Bot - cài đặt 1 lệnh trên Ubuntu
# Cài/cập nhật:  curl -fsSL https://raw.githubusercontent.com/USER/REPO/main/install.sh | sudo bash
# Sau khi cài:   zalo-backup help
set -euo pipefail

APP_DIR=/opt/zalo-backup
SERVICE=zalo-backup
PORT="${PORT:-3000}"

[ "$(id -u)" -eq 0 ] || { echo "Chạy bằng root: sudo bash install.sh"; exit 1; }

if [ "${1:-}" = "uninstall" ]; then
  systemctl disable --now $SERVICE 2>/dev/null || true
  rm -f /etc/systemd/system/$SERVICE.service /usr/local/bin/zalo-backup
  systemctl daemon-reload
  echo "Đã gỡ service. Dữ liệu vẫn còn ở $APP_DIR (xóa tay nếu không cần)."
  exit 0
fi

echo ">> Cài Node.js..."
NODE_MAJOR=0
command -v node >/dev/null && NODE_MAJOR=$(node -p "process.versions.node.split('.')[0]")
if [ "$NODE_MAJOR" -lt 18 ]; then
  apt-get update -y
  apt-get install -y curl ca-certificates
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y nodejs
fi

echo ">> Tạo $APP_DIR..."
mkdir -p $APP_DIR/backup
cd $APP_DIR

cat > package.json <<'PKG'
{
  "name": "zalo-backup",
  "version": "2.0.0",
  "type": "module",
  "main": "server.js",
  "dependencies": { "zca-js": "latest", "express": "^4" }
}
PKG

cat > server.js <<'JS'
import { Zalo, LoginQRCallbackEventType } from "zca-js";
import express from "express";
import fs from "fs";
import path from "path";
import { Readable } from "stream";
import { pipeline } from "stream/promises";
import {
  BACKUP_DIR, allowed, loadNames, setName, markRecalled, notify, freeGB, maintenance, registerViewer,
} from "./lib.mjs";

const CRED = "./cred.json";
const PORT = process.env.PORT || 3000;
const HOST = process.env.HOST || "0.0.0.0";
const AUTH_USER = process.env.AUTH_USER;
const AUTH_PASS = process.env.AUTH_PASS;
const MEDIA_DAYS = Number(process.env.MEDIA_DAYS) || 10;       // xóa media sau N ngày
const TEXT_DAYS = Number(process.env.TEXT_DAYS) || 0;          // xóa tin chữ sau N ngày (0 = giữ mãi)
const COMPRESS_DAYS = Number(process.env.COMPRESS_DAYS) || 0;  // nén gzip file ngày cũ hơn N ngày (0 = tắt)
const MAX_FILE_MB = Number(process.env.MAX_FILE_MB) || 20;     // bỏ qua file lớn hơn
const MIN_FREE_GB = Number(process.env.MIN_FREE_GB) || 2;      // dừng tải media khi ổ đĩa còn ít hơn
fs.mkdirSync(BACKUP_DIR, { recursive: true });

let qrImage = null, status = "init";

// ---------- Web ----------
const app = express();
app.use((req, res, next) => {
  const h = req.headers.authorization || "";
  const dec = Buffer.from(h.slice(6), "base64").toString();
  const i = dec.indexOf(":");
  if (AUTH_USER && dec.slice(0, i) === AUTH_USER && dec.slice(i + 1) === AUTH_PASS) return next();
  res.set("WWW-Authenticate", 'Basic realm="zalo"').status(401).end();
});
registerViewer(app);
app.get("/", (_, res) => res.send(
  `<meta name=viewport content="width=device-width"><meta http-equiv=refresh content=3>` +
  `<h3>Trạng thái: ${status}</h3><p><a href="/view">Xem tin nhắn đã lưu</a></p>` +
  (qrImage ? `<img src="${qrImage.startsWith("data:") ? qrImage : "data:image/png;base64," + qrImage}">` : "")));
app.listen(PORT, HOST, () => console.log(`Web: http://${HOST}:${PORT}`));

// ---------- Đăng nhập ----------
const zalo = new Zalo({ selfListen: true });

async function notifyQR() {
  let ip = "IP-VPS";
  try { ip = await (await fetch("https://api.ipify.org", { signal: AbortSignal.timeout(4000) })).text(); } catch {}
  const base = process.env.DOMAIN ? `https://${process.env.DOMAIN}${process.env.HTTPS_PORT ? ":" + process.env.HTTPS_PORT : ""}` : `http://${ip}:${PORT}`;
  await notify(`🔑 Zalo Backup cần quét QR đăng nhập lại: ${base}`, "qr", 6 * 3600e3);
}

async function login() {
  if (fs.existsSync(CRED)) {
    try { return await zalo.login(JSON.parse(fs.readFileSync(CRED))); }
    catch { console.log("Cred hết hạn, quét QR lại"); }
  }
  return await zalo.loginQR({}, (e) => {
    switch (e.type) {
      case LoginQRCallbackEventType.QRCodeGenerated:
        qrImage = e.data.image; status = "Quét QR bằng app Zalo"; notifyQR(); break;
      case LoginQRCallbackEventType.QRCodeScanned:
        status = "Đã quét: " + e.data.display_name + " - xác nhận trên điện thoại"; break;
      case LoginQRCallbackEventType.QRCodeExpired:
        e.actions.retry(); break;
      case LoginQRCallbackEventType.GotLoginInfo:
        fs.writeFileSync(CRED, JSON.stringify({
          cookie: e.data.cookie, imei: e.data.imei, userAgent: e.data.userAgent
        }), { mode: 0o600 }); break;
    }
  });
}

// ---------- Media ----------
const MEDIA_EXT = { "chat.photo": ".jpg", "chat.voice": ".aac", "chat.video.msg": ".mp4", "share.file": "" };
const safe = (n) => String(n).replace(/[^\w.\-()\u00C0-\u1EF9 ]/g, "_").slice(0, 120);

async function saveMedia(m) {
  const t = m.data.msgType;
  if (!(t in MEDIA_EXT)) return null;
  const c = m.data.content;
  if (!c || typeof c !== "object") return null;
  const url = c.href || c.thumb;
  if (!url) return null;
  if (freeGB() < MIN_FREE_GB) return "skipped: disk low";

  const limit = MAX_FILE_MB * 1024 * 1024;
  const res = await fetch(url);
  if (!res.ok) return "failed: HTTP " + res.status;
  if (Number(res.headers.get("content-length") || 0) > limit) return "skipped: too large";

  let name = t === "share.file" && c.title ? c.title : "file" + (MEDIA_EXT[t] || "");
  if (!path.extname(name)) name += MEDIA_EXT[t] || "";
  const dir = path.join(BACKUP_DIR, String(m.threadId), "media");
  fs.mkdirSync(dir, { recursive: true });
  const file = path.join(dir, m.data.msgId + "_" + safe(name));

  let size = 0;
  try {
    await pipeline(
      Readable.fromWeb(res.body),
      async function* (src) { for await (const ch of src) { size += ch.length; if (size > limit) throw new Error("too large"); yield ch; } },
      fs.createWriteStream(file)
    );
  } catch (e) { fs.rmSync(file, { force: true }); return "skipped: " + e.message; }
  return path.relative(BACKUP_DIR, file);
}

// ---------- Tên hội thoại ----------
async function updateName(api, m) {
  const id = String(m.threadId), cur = loadNames()[id];
  if (m.type === 1) {
    const stale = !cur || (cur.type === "group" && Date.now() - (cur.at || 0) > (cur.name ? 7 * 86400e3 : 3600e3));
    if (!stale) return;
    let name = cur?.name || "";
    try { const r = await api.getGroupInfo(id); name = r?.gridInfoMap?.[id]?.name || name; } catch {}
    setName(id, { name, type: "group", at: Date.now() });
  } else if (!m.isSelf && m.data.dName && cur?.name !== m.data.dName) {
    setName(id, { name: m.data.dName, type: "user" });
  } else if (!cur) {
    setName(id, { name: "", type: "user" });
  }
}

function writeLine(id, time, obj) {
  const dir = path.join(BACKUP_DIR, id);
  fs.mkdirSync(dir, { recursive: true });
  fs.appendFileSync(path.join(dir, time.slice(0, 10) + ".jsonl"), JSON.stringify(obj) + "\n");
}

// ---------- Bảo trì định kỳ ----------
async function housekeeping() {
  try {
    const r = maintenance({ mediaDays: MEDIA_DAYS, textDays: TEXT_DAYS, compressDays: COMPRESS_DAYS });
    if (r.media || r.text || r.compressed) console.log(`Dọn dẹp: xóa ${r.media} media, ${r.text} file tin chữ; nén ${r.compressed} file`);
    const f = freeGB();
    if (f < MIN_FREE_GB * 2) await notify(`💾 Ổ đĩa VPS chỉ còn ${f.toFixed(1)} GB (dưới ${MIN_FREE_GB * 2} GB). Bot sẽ ngừng tải media khi còn dưới ${MIN_FREE_GB} GB.`, "disk", 12 * 3600e3);
  } catch (e) { console.error("housekeeping", e); }
}
housekeeping();
setInterval(housekeeping, 3600e3);

// ---------- Main ----------
const api = await login();
status = "Online - đang sao lưu"; qrImage = null;
notify("✅ Zalo Backup đã đăng nhập và đang sao lưu.", "online", 600e3);

api.listener.on("message", async (m) => {
  try {
    const id = String(m.threadId);
    if (!allowed(id)) return;
    await updateName(api, m);
    const d = {
      time: new Date().toISOString(),
      threadId: m.threadId,
      thread: loadNames()[id]?.name || undefined,
      type: m.type,
      isSelf: m.isSelf,
      msgId: m.data.msgId,
      from: m.data.uidFrom,
      name: m.data.dName,
      msgType: m.data.msgType,
      content: m.data.content,
      ts: m.data.ts,
    };
    try { const r = await saveMedia(m); if (r) d.media = r; }
    catch (e) { d.media = "failed: " + e.message; }
    writeLine(id, d.time, d);
  } catch (e) { console.error("message error", e); }
});

// Tin bị thu hồi: bản gốc đã được lưu lúc nhận, chỉ cần đánh dấu
api.listener.on("undo", (u) => {
  try {
    const id = String(u.threadId);
    if (!allowed(id)) return;
    const target = String(u.data?.content?.globalMsgId ?? u.data?.msgId ?? "");
    const time = new Date().toISOString();
    writeLine(id, time, { time, event: "undo", threadId: u.threadId, isSelf: u.isSelf, targetMsgId: target, from: u.data?.uidFrom, raw: u.data });
    if (target) markRecalled(id, target);
  } catch (e) { console.error("undo error", e); }
});

api.listener.on("closed", async (code) => {
  console.log("closed", code);
  await notify(`⚠️ Zalo Backup mất kết nối (code ${code}), đang kết nối lại. Nếu lặp lại, kiểm tra xem có phiên Zalo Web khác đang mở không.`, "closed", 600e3);
  process.exit(1);
});
api.listener.on("error", (e) => console.error("listener error", e));
api.listener.start();
JS

cat > lib.mjs <<'LIB'
import fs from "fs";
import path from "path";
import zlib from "zlib";
import { execSync } from "child_process";

export const BACKUP_DIR = process.env.BACKUP_DIR || "./backup";
export const NAMES_FILE = process.env.NAMES_FILE || "./names.json";
export const FILTERS_FILE = process.env.FILTERS_FILE || "./filters.json";
const ALERTS_FILE = process.env.ALERTS_FILE || "./alerts.json";
export const DAY_RE = /^(\d{4}-\d{2}-\d{2})\.jsonl(\.gz)?$/;

// ---------- JSON helpers ----------
export function readJson(file, def) { try { return JSON.parse(fs.readFileSync(file, "utf8")); } catch { return def; } }
export function writeJson(file, v) { fs.writeFileSync(file + ".tmp", JSON.stringify(v, null, 2)); fs.renameSync(file + ".tmp", file); }
const _cache = {};
function cachedJson(file, def) {
  try {
    const mt = fs.statSync(file).mtimeMs, c = _cache[file];
    if (c && c.mt === mt) return c.v;
    const v = JSON.parse(fs.readFileSync(file, "utf8"));
    _cache[file] = { mt, v };
    return v;
  } catch { return def; }
}

// ---------- Tên hội thoại & bộ lọc ----------
export const loadNames = () => cachedJson(NAMES_FILE, {});
export function setName(id, patch) {
  const n = readJson(NAMES_FILE, {});
  n[id] = { ...(n[id] || {}), ...patch };
  writeJson(NAMES_FILE, n);
  delete _cache[NAMES_FILE];
}
export function loadFilters() {
  const f = cachedJson(FILTERS_FILE, {});
  return { ignore: (f.ignore || []).map(String), only: (f.only || []).map(String) };
}
export function allowed(threadId) {
  const f = loadFilters(), id = String(threadId);
  return f.only.length ? f.only.includes(id) : !f.ignore.includes(id);
}

// ---------- Đọc dữ liệu ----------
export function threadDirs() {
  try { return fs.readdirSync(BACKUP_DIR).filter((d) => { try { return fs.statSync(path.join(BACKUP_DIR, d)).isDirectory(); } catch { return false; } }); }
  catch { return []; }
}
export function threadDays(id) {
  try { return [...new Set(fs.readdirSync(path.join(BACKUP_DIR, id)).map((f) => DAY_RE.exec(f)).filter(Boolean).map((m) => m[1]))].sort(); }
  catch { return []; }
}
export function readDay(id, day) {
  const base = path.join(BACKUP_DIR, id, day + ".jsonl");
  let txt = "";
  try { txt = fs.existsSync(base) ? fs.readFileSync(base, "utf8") : zlib.gunzipSync(fs.readFileSync(base + ".gz")).toString("utf8"); } catch {}
  return txt.split("\n").filter(Boolean).map((l) => { try { return JSON.parse(l); } catch {} }).filter(Boolean);
}
export function recalledSet(id) {
  try { return new Set(fs.readFileSync(path.join(BACKUP_DIR, id, "recalled.txt"), "utf8").split("\n").filter(Boolean)); }
  catch { return new Set(); }
}
export function markRecalled(id, msgId) {
  fs.mkdirSync(path.join(BACKUP_DIR, id), { recursive: true });
  fs.appendFileSync(path.join(BACKUP_DIR, id, "recalled.txt"), msgId + "\n");
}
export const norm = (s) => String(s ?? "").toLowerCase().normalize("NFD").replace(/[\u0300-\u036f]/g, "").replace(/đ/g, "d");

export function msgText(m) {
  const c = m.content;
  if (typeof c === "string") return c;
  if (c && typeof c === "object") {
    const saved = m.media && !/^(skipped|failed)/.test(m.media);
    const bits = [c.title, c.description, saved ? "" : c.href].filter((x) => typeof x === "string" && x);
    return bits.length ? bits.join(" — ") : saved ? "" : JSON.stringify(c);
  }
  return "";
}
export const msgTime = (m) => Number(m.ts) || Date.parse(m.time) || 0;
export const fmtTime = (m) => new Date(msgTime(m)).toLocaleString("vi-VN", { timeZone: "Asia/Ho_Chi_Minh" });

export function searchAll(q, { limit = 100, threadId } = {}) {
  const nq = norm(q), out = [];
  const ids = threadId ? [String(threadId)] : threadDirs();
  const pairs = ids.flatMap((id) => threadDays(id).map((day) => [id, day])).sort((a, b) => b[1].localeCompare(a[1]));
  for (const [id, day] of pairs) {
    const msgs = readDay(id, day).filter((m) => !m.event);
    for (let i = msgs.length - 1; i >= 0; i--) {
      const m = msgs[i];
      if (norm(msgText(m) + " " + (m.name || "")).includes(nq)) { out.push({ m, day }); if (out.length >= limit) return out; }
    }
  }
  return out;
}
export function recentMsgs(n = 20) {
  const pairs = threadDirs().flatMap((id) => threadDays(id).map((day) => [id, day]));
  const days = [...new Set(pairs.map((p) => p[1]))].sort().reverse();
  let got = [], used = 0;
  for (const d of days) {
    for (const [id, day] of pairs) if (day === d) got.push(...readDay(id, day).filter((m) => !m.event));
    if (++used >= 3 && got.length >= n) break;
  }
  return got.sort((a, b) => msgTime(a) - msgTime(b)).slice(-n);
}

// ---------- Dung lượng, dọn dẹp, nén ----------
export function freeGB(dir = BACKUP_DIR) {
  try { const s = fs.statfsSync(dir); return (s.bavail * s.bsize) / 1e9; }
  catch { try { return Number(execSync(`df -k --output=avail "${dir}" | tail -1`).toString().trim()) / 1e6; } catch { return 999; } }
}
export function dirSize(p) {
  let t = 0;
  try { for (const f of fs.readdirSync(p)) { const q = path.join(p, f), s = fs.statSync(q); t += s.isDirectory() ? dirSize(q) : s.size; } } catch {}
  return t;
}
// mediaDays: xóa media cũ | textDays: xóa tin chữ cũ (0 = giữ mãi) | compressDays: nén gzip file ngày cũ (0 = tắt)
export function maintenance({ mediaDays = 10, textDays = 0, compressDays = 0 } = {}) {
  const r = { media: 0, text: 0, compressed: 0 };
  const now = Date.now(), dayStr = (ms) => new Date(ms).toISOString().slice(0, 10);
  const mediaCut = now - mediaDays * 86400e3;
  const textCut = textDays > 0 ? dayStr(now - textDays * 86400e3) : null;
  const zipCut = compressDays > 0 ? dayStr(now - compressDays * 86400e3) : null;
  for (const id of threadDirs()) {
    const td = path.join(BACKUP_DIR, id), md = path.join(td, "media");
    try {
      for (const f of fs.readdirSync(md)) {
        const p = path.join(md, f);
        try { if (fs.statSync(p).mtimeMs < mediaCut) { fs.rmSync(p); r.media++; } } catch {}
      }
    } catch {}
    try {
      for (const f of fs.readdirSync(td)) {
        const mm = DAY_RE.exec(f); if (!mm) continue;
        const p = path.join(td, f), day = mm[1];
        if (textCut && day < textCut) { fs.rmSync(p); r.text++; continue; }
        if (zipCut && !mm[2] && day < zipCut) { fs.writeFileSync(p + ".gz", zlib.gzipSync(fs.readFileSync(p))); fs.rmSync(p); r.compressed++; }
      }
    } catch {}
  }
  return r;
}

// ---------- Telegram ----------
export async function notify(text, key = "", cooldownMs = 0) {
  const tok = process.env.TG_TOKEN, chat = process.env.TG_CHAT;
  if (!tok || !chat) return false;
  if (key && cooldownMs) {
    const st = readJson(ALERTS_FILE, {});
    if (Date.now() - (st[key] || 0) < cooldownMs) return false;
    st[key] = Date.now(); try { writeJson(ALERTS_FILE, st); } catch {}
  }
  try {
    const r = await fetch(`https://api.telegram.org/bot${tok}/sendMessage`, {
      method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ chat_id: chat, text }), signal: AbortSignal.timeout(8000),
    });
    return r.ok;
  } catch { return false; }
}

// ---------- Render HTML (dùng cho web và export) ----------
export const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
export const CSS = `:root{color-scheme:light dark;--bg:#fff;--fg:#111;--mut:#667;--me:#d6ecff;--ot:#f0f0f3;--bd:#ddd}
@media(prefers-color-scheme:dark){:root{--bg:#121316;--fg:#e8e8ea;--mut:#9a9aa5;--me:#1f3b5c;--ot:#23252b;--bd:#333}}
body{font:15px/1.45 system-ui,sans-serif;background:var(--bg);color:var(--fg);max-width:760px;margin:auto;padding:12px}
a{color:#3b82f6;text-decoration:none}h2,h3{margin:.6em 0}
input,select,button{font:inherit;padding:6px 8px;border:1px solid var(--bd);border-radius:8px;background:var(--bg);color:var(--fg)}
input[name=q]{width:70%}.row{display:flex;justify-content:space-between;gap:8px;padding:10px 4px;border-bottom:1px solid var(--bd);color:var(--fg)}
.msg{margin:6px 0;padding:8px 10px;border-radius:12px;background:var(--ot);max-width:88%;white-space:pre-wrap;word-break:break-word}
.msg.me{background:var(--me);margin-left:auto}.meta{font-size:12px;color:var(--mut);white-space:normal}.rc{color:#e11d48;font-weight:600}
img,video{max-width:100%;border-radius:8px;display:block;margin-top:6px}audio{width:100%;margin-top:6px}
.nav{display:flex;justify-content:space-between;align-items:center;gap:8px;margin:8px 0}`;
export const page = (title, body) => `<!doctype html><html lang=vi><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1"><title>${esc(title)}</title><style>${CSS}</style><body>${body}</body></html>`;

export function renderMsg(m, rec, opt = {}) {
  const rc = rec.has(String(m.msgId));
  let media = "";
  if (m.media) {
    if (/^(skipped|failed)/.test(m.media)) media = `<div class=meta>⚠ ${esc(m.media)}</div>`;
    else {
      const f = path.basename(m.media);
      if (opt.exists && !opt.exists(f)) media = `<div class=meta>📎 ${esc(f)} (đã xóa)</div>`;
      else {
        const u = (opt.prefix || "") + encodeURIComponent(f), ext = path.extname(f).toLowerCase();
        media = /^\.(jpe?g|png|gif|webp)$/.test(ext) ? `<a href="${u}"><img loading=lazy src="${u}"></a>`
          : /^\.(aac|m4a|mp3|ogg|wav)$/.test(ext) ? `<audio controls preload=none src="${u}"></audio>`
          : /^\.(mp4|webm|mov)$/.test(ext) ? `<video controls preload=none src="${u}"></video>`
          : `<div><a href="${u}">📎 ${esc(f)}</a></div>`;
      }
    }
  }
  return `<div class="msg${m.isSelf ? " me" : ""}" id="m${esc(m.msgId)}"><div class=meta>${esc(m.name || m.from || "")} · ${esc(fmtTime(m))}${rc ? ' · <span class=rc>🗑 ĐÃ THU HỒI</span>' : ""}</div>${esc(msgText(m))}${media}</div>`;
}

// ---------- Web viewer ----------
export function registerViewer(app) {
  const idOk = (s) => /^[\w-]+$/.test(String(s));
  const nameOf = (id) => loadNames()[id]?.name || id;

  app.get("/view", (req, res) => {
    const names = loadNames(), f = loadFilters();
    const rows = threadDirs().map((id) => { const d = threadDays(id); return { id, last: d[d.length - 1] || "" }; })
      .sort((a, b) => b.last.localeCompare(a.last));
    const li = rows.map((r) => {
      const nm = names[r.id], off = f.only.length ? !f.only.includes(r.id) : f.ignore.includes(r.id);
      return `<a class=row href="/view/t/${r.id}"><span>${nm?.type === "group" ? "👥" : "👤"} ${esc(nm?.name || r.id)}${off ? " 🚫" : ""}</span><span class=meta>${esc(r.last)}</span></a>`;
    }).join("");
    res.send(page("Tin nhắn Zalo", `<h2>Tin nhắn đã lưu</h2><form action=/view/search><input name=q placeholder="Tìm kiếm (không cần dấu)..."> <button>Tìm</button></form>${li || "<p>Chưa có tin nào.</p>"}<p class=meta><a href="/">← Trạng thái</a></p>`));
  });

  app.get("/view/t/:id", (req, res) => {
    const id = req.params.id;
    if (!idOk(id)) return res.status(400).end();
    const days = threadDays(id);
    if (!days.length) return res.status(404).send(page("404", "<p>Không có dữ liệu.</p><a href=/view>← Về danh sách</a>"));
    const q = String(req.query.d || "");
    const d = days.includes(q) ? q : days[days.length - 1], i = days.indexOf(d);
    const rec = recalledSet(id);
    const msgs = readDay(id, d).filter((m) => !m.event).sort((a, b) => msgTime(a) - msgTime(b)).slice(-3000);
    const opt = { prefix: `/view/media/${id}/`, exists: (f) => fs.existsSync(path.join(BACKUP_DIR, id, "media", f)) };
    const nav = `<div class=nav>${i > 0 ? `<a href="?d=${days[i - 1]}">‹ ${days[i - 1]}</a>` : "<span></span>"}
<select onchange="location='?d='+this.value">${days.slice(-400).reverse().map((x) => `<option${x === d ? " selected" : ""}>${x}</option>`).join("")}</select>
${i < days.length - 1 ? `<a href="?d=${days[i + 1]}">${days[i + 1]} ›</a>` : "<span></span>"}</div>`;
    res.send(page(nameOf(id), `<a href=/view>← Danh sách</a><h2>${esc(nameOf(id))}</h2>${nav}${msgs.map((m) => renderMsg(m, rec, opt)).join("") || "<p>Không có tin.</p>"}${nav}`));
  });

  app.get("/view/search", (req, res) => {
    const q = String(req.query.q || "").trim();
    let body = `<a href=/view>← Danh sách</a><h2>Tìm kiếm</h2><form><input name=q value="${esc(q)}"> <button>Tìm</button></form>`;
    if (q) {
      const hits = searchAll(q, { limit: 200 });
      body += `<p class=meta>${hits.length} kết quả (mới nhất trước)</p>` + hits.map(({ m, day }) =>
        `<a class=row style="display:block" href="/view/t/${esc(m.threadId)}?d=${day}#m${esc(m.msgId)}"><div class=meta>${esc(nameOf(String(m.threadId)))} · ${esc(m.name || "")} · ${esc(fmtTime(m))}</div>${esc(msgText(m).slice(0, 300))}</a>`).join("");
    }
    res.send(page("Tìm kiếm", body));
  });

  app.get("/view/media/:id/:file", (req, res) => {
    const id = req.params.id, f = path.basename(req.params.file);
    if (!idOk(id)) return res.status(400).end();
    const p = path.resolve(BACKUP_DIR, id, "media", f);
    const inline = /\.(jpe?g|png|gif|webp|aac|m4a|mp3|ogg|wav|mp4|webm|mov)$/i.test(f);
    res.set({ "Content-Security-Policy": "sandbox", "X-Content-Type-Options": "nosniff" });
    if (!inline) res.attachment(f);
    res.sendFile(p, { dotfiles: "deny" }, (err) => { if (err && !res.headersSent) res.status(404).end(); });
  });
}
LIB

cat > tool.mjs <<'TOOL'
import fs from "fs";
import path from "path";
import {
  BACKUP_DIR, FILTERS_FILE, loadNames, loadFilters, threadDirs, threadDays, readDay, recalledSet,
  searchAll, recentMsgs, msgText, msgTime, fmtTime, renderMsg, page, esc, norm, dirSize, maintenance,
} from "./lib.mjs";

const [cmd, ...args] = process.argv.slice(2);
const names = loadNames();
const nameOf = (id) => names[id]?.name || id;
const die = (s) => { console.error(s); process.exit(1); };
const safe = (s) => String(s).replace(/[^\w.\-\u00C0-\u1EF9]+/g, "_").slice(0, 60);
const human = (b) => (b > 1e9 ? (b / 1e9).toFixed(1) + "G" : b > 1e6 ? (b / 1e6).toFixed(1) + "M" : (b / 1e3).toFixed(0) + "K");
const recCache = {};
const rec = (id) => (recCache[id] ??= recalledSet(id));

function line(m) {
  const id = String(m.threadId), ok = m.media && !/^(skipped|failed)/.test(m.media);
  return `${fmtTime(m)} ${m.isSelf ? "→" : "←"} [${m.thread || nameOf(id)}] ${m.name || m.from || ""}: ${msgText(m)}` +
    `${rec(id).has(String(m.msgId)) ? "  🗑[ĐÃ THU HỒI]" : ""}${ok ? "  📎" + m.media : ""}`;
}
function resolve(arg) {
  if (!arg) die("Thiếu hội thoại (id hoặc tên). Xem: zalo-backup threads");
  const ids = threadDirs();
  if (ids.includes(arg) || /^\d+$/.test(arg)) return arg;
  const n = norm(arg), hit = ids.filter((id) => norm(nameOf(id)).includes(n));
  if (hit.length === 1) return hit[0];
  if (!hit.length) die(`Không tìm thấy hội thoại "${arg}". Xem: zalo-backup threads`);
  die("Nhiều kết quả, hãy dùng id:\n" + hit.map((id) => `  ${id}  ${nameOf(id)}`).join("\n"));
}
const saveFilters = (f) => fs.writeFileSync(FILTERS_FILE, JSON.stringify(f, null, 2));

switch (cmd) {
  case "search": {
    if (!args.length) die("Dùng: zalo-backup search <từ khóa>");
    const hits = searchAll(args.join(" "), { limit: 100 }).reverse();
    hits.forEach(({ m }) => console.log(line(m)));
    console.log(`-- ${hits.length} kết quả (tối đa 100, mới nhất)`);
    break;
  }
  case "recent": recentMsgs(Number(args[0]) || 20).forEach((m) => console.log(line(m))); break;
  case "recalled": {
    const out = [];
    for (const id of threadDirs()) {
      const r = rec(id); if (!r.size) continue;
      for (const d of threadDays(id)) for (const m of readDay(id, d)) if (!m.event && r.has(String(m.msgId))) out.push(m);
    }
    out.sort((a, b) => msgTime(a) - msgTime(b)).slice(-(Number(args[0]) || 20)).forEach((m) => console.log(line(m)));
    if (!out.length) console.log("Chưa có tin nào bị thu hồi.");
    break;
  }
  case "threads": {
    const f = loadFilters();
    const rows = threadDirs().map((id) => {
      const d = threadDays(id), off = f.only.length ? !f.only.includes(id) : f.ignore.includes(id);
      return { id, type: names[id]?.type === "group" ? "nhóm" : "cá nhân", name: nameOf(id), size: dirSize(path.join(BACKUP_DIR, id)), last: d[d.length - 1] || "", off };
    });
    rows.sort(args[0] === "--size" ? (a, b) => b.size - a.size : (a, b) => b.last.localeCompare(a.last));
    for (const r of rows) console.log(`${r.id.padEnd(22)} ${r.type.padEnd(8)} ${human(r.size).padStart(6)}  ${r.last}  ${r.off ? "🚫 " : ""}${r.name}`);
    if (!rows.length) console.log("Chưa có hội thoại nào.");
    break;
  }
  case "ignore": { const id = resolve(args[0]), f = loadFilters(); if (!f.ignore.includes(id)) f.ignore.push(id); saveFilters(f); console.log(`Đã bỏ qua: ${nameOf(id)} (${id})` + (f.only.length ? "\n(Lưu ý: đang bật chế độ 'only', danh sách bỏ qua chỉ có tác dụng khi tắt 'only')" : "")); break; }
  case "unignore": { const id = resolve(args[0]), f = loadFilters(); f.ignore = f.ignore.filter((x) => x !== id); saveFilters(f); console.log(`Đã bỏ chặn: ${nameOf(id)} (${id})`); break; }
  case "only": {
    const f = loadFilters();
    if (args[0] === "off" || !args.length) { f.only = []; saveFilters(f); console.log("Đã tắt chế độ 'only' (lưu mọi hội thoại trừ danh sách bỏ qua)."); break; }
    f.only = args.map(resolve); saveFilters(f);
    console.log("Chỉ lưu:\n" + f.only.map((id) => `  ${id}  ${nameOf(id)}`).join("\n"));
    break;
  }
  case "filters": {
    const f = loadFilters();
    console.log(f.only.length ? "Chế độ ONLY (chỉ lưu):\n" + f.only.map((id) => `  ${id}  ${nameOf(id)}`).join("\n") : "Chế độ thường (lưu tất cả trừ danh sách bỏ qua)");
    console.log("Bỏ qua:" + (f.ignore.length ? "\n" + f.ignore.map((id) => `  ${id}  ${nameOf(id)}`).join("\n") : " (trống)"));
    break;
  }
  case "export": {
    const id = resolve(args[0]), from = args[1] || "0000", to = args[2] || "9999";
    const days = threadDays(id).filter((d) => d >= from && d <= to);
    if (!days.length) die("Không có dữ liệu trong khoảng này.");
    const stamp = new Date().toISOString().replace(/[-:T]/g, "").slice(0, 14);
    const out = path.join("export", `${safe(nameOf(id))}_${stamp}`);
    fs.mkdirSync(path.join(out, "media"), { recursive: true });
    const r = rec(id), srcMedia = path.join(BACKUP_DIR, id, "media");
    const opt = { prefix: "media/", exists: (f) => fs.existsSync(path.join(srcMedia, f)) };
    let txt = "", html = `<h2>${esc(nameOf(id))}</h2>`, n = 0, copied = 0;
    for (const d of days) {
      const msgs = readDay(id, d).filter((m) => !m.event).sort((a, b) => msgTime(a) - msgTime(b));
      if (!msgs.length) continue;
      html += `<h3>${d}</h3>`;
      for (const m of msgs) {
        n++; txt += line(m) + "\n"; html += renderMsg(m, r, opt);
        if (m.media && !/^(skipped|failed)/.test(m.media)) {
          const f = path.basename(m.media), s = path.join(srcMedia, f);
          if (fs.existsSync(s)) { fs.copyFileSync(s, path.join(out, "media", f)); copied++; }
        }
      }
    }
    fs.writeFileSync(path.join(out, "chat.txt"), txt);
    fs.writeFileSync(path.join(out, "chat.html"), page(nameOf(id), html));
    console.log(`Đã xuất ${n} tin, ${copied} file media ra: ${path.resolve(out)}\n(chat.html, chat.txt, media/) — tải về bằng scp hoặc zip.`);
    break;
  }
  case "clean": {
    const r = maintenance({ mediaDays: Number(process.env.MEDIA_DAYS) || 10, textDays: Number(process.env.TEXT_DAYS) || 0, compressDays: Number(process.env.COMPRESS_DAYS) || 0 });
    console.log(`Xóa ${r.media} media quá hạn, xóa ${r.text} file tin chữ quá hạn, nén ${r.compressed} file.`);
    break;
  }
  default: die("Lệnh không hợp lệ");
}
TOOL

rm -f fmt.mjs

echo ">> Cài lệnh quản lý zalo-backup..."
cat > /usr/local/bin/zalo-backup <<'CLI'
#!/usr/bin/env bash
APP=/opt/zalo-backup; SVC=zalo-backup; ENVF=$APP/.env; BK=$APP/backup
[ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"
getv() { grep -E "^$1=" "$ENVF" | head -1 | cut -d= -f2-; }
setv() { { grep -v "^$1=" "$ENVF" || true; echo "$1=$2"; } > "$ENVF.tmp"; mv "$ENVF.tmp" "$ENVF"; chmod 600 "$ENVF"; }
delv() { { grep -v "^$1=" "$ENVF" || true; } > "$ENVF.tmp"; mv "$ENVF.tmp" "$ENVF"; chmod 600 "$ENVF"; }
ip() { curl -fsS --max-time 4 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}'; }
url() { if [ -n "$(getv DOMAIN)" ]; then echo "https://$(getv DOMAIN)$( [ -n "$(getv HTTPS_PORT)" ] && echo ":$(getv HTTPS_PORT)")"; else echo "http://$(ip):$(getv PORT)"; fi; }
tool() { (cd "$APP" && node tool.mjs "$@"); }
tg() { curl -fsS --max-time 10 "https://api.telegram.org/bot$1/sendMessage" -d "chat_id=$2" --data-urlencode "text=$3"; }

case "${1:-help}" in
  status)
    echo "Service:   $(systemctl is-active $SVC)"
    [ -f $APP/cred.json ] && echo "Đăng nhập: có phiên Zalo đã lưu" || echo "Đăng nhập: CHƯA - mở $(url) quét QR"
    echo "Backup:    $(du -sh $BK 2>/dev/null | cut -f1) | ổ đĩa trống $(df -h --output=avail $BK | tail -1 | xargs)"
    echo "Hội thoại: $(ls $BK 2>/dev/null | wc -l)"
    echo "Tin hôm nay (UTC): $(cat $BK/*/$(date -u +%F).jsonl 2>/dev/null | wc -l)"
    echo "Media:     $(find $BK -path '*/media/*' -type f 2>/dev/null | wc -l) file, $(du -ch $BK/*/media 2>/dev/null | tail -1 | cut -f1)"
    echo "Giữ:       media $(getv MEDIA_DAYS) ngày, tin chữ $( [ "$(getv TEXT_DAYS)" = 0 ] && echo vĩnh viễn || echo "$(getv TEXT_DAYS) ngày"), nén sau $( [ "$(getv COMPRESS_DAYS)" = 0 ] && echo "(tắt)" || echo "$(getv COMPRESS_DAYS) ngày")"
    echo "Telegram:  $( [ -n "$(getv TG_TOKEN)" ] && echo bật || echo tắt)"
    echo "Web xem tin: $(url)/view" ;;
  info)    echo "Web: $(url)  (xem tin: $(url)/view)"; echo "User: $(getv AUTH_USER)"; echo "Pass: $(getv AUTH_PASS)" ;;
  logs)    journalctl -u $SVC -n "${2:-50}" -f --no-pager ;;
  start|stop|restart) systemctl "$1" $SVC && echo "OK: $1" ;;
  logout)
    systemctl stop $SVC; rm -f $APP/cred.json; systemctl start $SVC
    echo "Đã xóa phiên đăng nhập. Mở $(url) để quét QR tài khoản mới."
    echo "(Muốn chắc chắn: vào Zalo > Cài đặt > Thiết bị đăng nhập, xóa thiết bị cũ.)" ;;
  config)  sed -E 's/^(AUTH_PASS|TG_TOKEN)=.+/\1=******/' "$ENVF" ;;
  set)
    k="${2:-}"; v="${3:-}"
    case "$k" in MEDIA_DAYS|TEXT_DAYS|COMPRESS_DAYS|MAX_FILE_MB|MIN_FREE_GB|PORT|HOST|AUTH_USER|AUTH_PASS) ;;
      *) echo "Khóa hợp lệ: MEDIA_DAYS TEXT_DAYS COMPRESS_DAYS MAX_FILE_MB MIN_FREE_GB PORT HOST AUTH_USER AUTH_PASS"; exit 1 ;; esac
    [ -n "$v" ] || { echo "Thiếu giá trị"; exit 1; }
    setv "$k" "$v"; systemctl restart $SVC; echo "Đã đặt $k và khởi động lại." ;;
  days)
    [ -n "${2:-}" ] || { echo "Dùng: zalo-backup days <ngày giữ media> [ngày giữ tin chữ, 0 = vĩnh viễn]"; exit 1; }
    setv MEDIA_DAYS "$2"; [ -n "${3:-}" ] && setv TEXT_DAYS "$3"
    systemctl restart $SVC; echo "Media: $(getv MEDIA_DAYS) ngày, tin chữ: $(getv TEXT_DAYS) ngày (0 = vĩnh viễn)" ;;
  passwd)
    p="${2:-$(head -c 9 /dev/urandom | od -An -tx1 | tr -d ' \n')}"
    setv AUTH_PASS "$p"; systemctl restart $SVC; echo "Mật khẩu web mới: $p" ;;
  telegram)
    case "${2:-}" in
      off) delv TG_TOKEN; delv TG_CHAT; systemctl restart $SVC; echo "Đã tắt cảnh báo Telegram." ;;
      test) tg "$(getv TG_TOKEN)" "$(getv TG_CHAT)" "🔔 Zalo Backup: tin nhắn thử" >/dev/null && echo "Đã gửi, kiểm tra Telegram." || echo "Gửi lỗi, kiểm tra token/chat id." ;;
      "") echo "Dùng: zalo-backup telegram <bot_token> <chat_id> | test | off"; exit 1 ;;
      *) [ -n "${3:-}" ] || { echo "Dùng: zalo-backup telegram <bot_token> <chat_id>"; exit 1; }
         if tg "$2" "$3" "✅ Zalo Backup đã kết nối Telegram" >/dev/null; then
           setv TG_TOKEN "$2"; setv TG_CHAT "$3"; systemctl restart $SVC; echo "OK: đã bật cảnh báo Telegram."
         else echo "Gửi thử thất bại: kiểm tra token, chat id, và đã nhắn /start cho bot chưa."; exit 1; fi ;;
    esac ;;
  nginx)
    d="${2:-}"
    if [ "$d" = off ]; then
      rm -f /etc/nginx/sites-enabled/zalo-backup /etc/nginx/sites-available/zalo-backup
      nginx -t && systemctl reload nginx
      delv DOMAIN; delv HTTPS_PORT; setv HOST 0.0.0.0; systemctl restart $SVC
      echo "Đã gỡ cấu hình Nginx, web lại mở trực tiếp ở cổng $(getv PORT)."; exit 0
    fi
    [ -n "$d" ] || { echo "Dùng: zalo-backup nginx <tên-miền> [email]   (tên miền phải trỏ A record về IP VPS)"; echo "      zalo-backup nginx off"; exit 1; }
    command -v nginx >/dev/null || { apt-get update -y && apt-get install -y nginx; }
    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
    CONF=/etc/nginx/sites-available/zalo-backup
    reload_nginx() { if systemctl is-active --quiet nginx; then systemctl reload nginx; else systemctl enable --now nginx; fi; }
    busy=$(ss -tlnp | awk '$4 ~ /:(80|443)$/ && $0 !~ /nginx/' | wc -l)

    if [ "$busy" -gt 0 ]; then
      # Cổng 80/443 đang bị chương trình khác (vd psiphond) giữ -> HTTPS cổng 8443 với chứng chỉ tự ký
      sp=8443
      [ "$(ss -tlnp | awk -v p=":$sp$" '$4 ~ p && $0 !~ /nginx/' | wc -l)" -eq 0 ] || { echo "Cổng $sp cũng đang bị dùng, giải phóng cổng này rồi chạy lại."; exit 1; }
      echo "Cổng 80/443 đang bị chương trình khác dùng (psiphond?), chuyển sang HTTPS cổng $sp với chứng chỉ tự ký."
      mkdir -p /etc/ssl/private /etc/ssl/certs
      openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout /etc/ssl/private/zalo-backup.key \
        -out /etc/ssl/certs/zalo-backup.crt -subj "/CN=$d" -addext "subjectAltName=DNS:$d" 2>/dev/null \
        || { echo "Tạo chứng chỉ lỗi (cần openssl)."; exit 1; }
      chmod 600 /etc/ssl/private/zalo-backup.key
      cat > $CONF <<'NG'
server {
    listen @SP@ ssl;
    server_name @DOMAIN@;
    ssl_certificate /etc/ssl/certs/zalo-backup.crt;
    ssl_certificate_key /etc/ssl/private/zalo-backup.key;
    client_max_body_size 1m;
    location / {
        proxy_pass http://127.0.0.1:@PORT@;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 120s;
    }
}
NG
      sed -i "s/@DOMAIN@/$d/; s/@PORT@/$(getv PORT)/; s/@SP@/$sp/" $CONF
      ln -sf $CONF /etc/nginx/sites-enabled/zalo-backup
      nginx -t || { rm -f /etc/nginx/sites-enabled/zalo-backup; echo "Cấu hình Nginx lỗi, đã hoàn tác."; exit 1; }
      reload_nginx
      setv DOMAIN "$d"; setv HTTPS_PORT "$sp"; setv HOST 127.0.0.1; systemctl restart $SVC
      echo "Xong: https://$d:$sp/view"
      echo "- Trình duyệt sẽ cảnh báo chứng chỉ tự ký: bấm 'Nâng cao' > 'Tiếp tục truy cập' (kết nối vẫn được mã hóa)."
      echo "- Nếu dùng ufw: ufw allow $sp/tcp. Cổng $(getv PORT) giờ chỉ truy cập nội bộ."
      exit 0
    fi

    cat > $CONF <<'NG'
server {
    listen 80;
    server_name @DOMAIN@;
    client_max_body_size 1m;
    location / {
        proxy_pass http://127.0.0.1:@PORT@;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 120s;
    }
}
NG
    sed -i "s/@DOMAIN@/$d/; s/@PORT@/$(getv PORT)/" $CONF
    ln -sf $CONF /etc/nginx/sites-enabled/zalo-backup
    nginx -t || { rm -f /etc/nginx/sites-enabled/zalo-backup; echo "Cấu hình Nginx lỗi, đã hoàn tác."; exit 1; }
    reload_nginx
    command -v certbot >/dev/null || apt-get install -y certbot python3-certbot-nginx
    if [ -n "${3:-}" ]; then em=(-m "$3"); else em=(--register-unsafely-without-email); fi
    if certbot --nginx -d "$d" --non-interactive --agree-tos "${em[@]}" --redirect; then
      setv DOMAIN "$d"; delv HTTPS_PORT; setv HOST 127.0.0.1; systemctl restart $SVC
      echo "Xong: https://$d  (xem tin: https://$d/view). Cổng $(getv PORT) giờ chỉ nội bộ."
    else
      echo "Không lấy được chứng chỉ HTTPS. Kiểm tra: tên miền đã trỏ về VPS chưa, cổng 80/443 đã mở chưa (ufw allow 80,443/tcp)."
      echo "Web vẫn chạy bình thường ở cổng $(getv PORT); chạy lại lệnh sau khi sửa."; exit 1
    fi ;;
  search|recent|recalled|threads|ignore|unignore|only|filters|export) tool "$@" ;;
  stats) tool threads --size ;;
  clean) (cd "$APP" && set -a && . ./.env && set +a && node tool.mjs clean) ;;
  update)
    [ -n "${2:-}" ] && setv INSTALL_URL "$2"
    u=$(getv INSTALL_URL); [ -n "$u" ] || { echo "Dùng: zalo-backup update <link raw install.sh> (chỉ cần nhập lần đầu)"; exit 1; }
    curl -fsSL "$u" | bash ;;
  uninstall)
    systemctl disable --now $SVC 2>/dev/null; rm -f /etc/systemd/system/$SVC.service /usr/local/bin/zalo-backup
    systemctl daemon-reload; echo "Đã gỡ. Dữ liệu còn ở $APP (xóa tay nếu không cần)." ;;
  *)
    cat <<H
zalo-backup <lệnh>
 Vận hành
  status | info | logs [n] | start | stop | restart
  logout               Đăng xuất, quét QR tài khoản khác
  days M [T]           Giữ media M ngày, tin chữ T ngày (0 = vĩnh viễn)
  set KEY VALUE        MEDIA_DAYS TEXT_DAYS COMPRESS_DAYS MAX_FILE_MB MIN_FREE_GB PORT HOST AUTH_USER AUTH_PASS
  config | passwd [mới] | clean | update [link] | uninstall
  nginx <tên-miền> [email]   Bật HTTPS qua Nginx (Let's Encrypt; nếu cổng 80/443 bị chiếm thì tự dùng cổng 8443 tự ký). nginx off để gỡ
 Cảnh báo
  telegram <token> <chat_id> | test | off
 Xem & tìm tin
  threads              Danh sách hội thoại (tên, dung lượng, trạng thái)
  stats                Như threads, xếp theo dung lượng
  search <từ khóa>     Tìm (không cần dấu)
  recent [n]           n tin gần nhất
  recalled [n]         Tin đã bị thu hồi
  export <hội thoại> [từ YYYY-MM-DD] [đến YYYY-MM-DD]   Xuất ra HTML/txt
 Lọc hội thoại (áp dụng ngay, không cần restart)
  ignore <id|tên>      Ngừng lưu hội thoại này
  unignore <id|tên>
  only <id|tên>...     Chỉ lưu các hội thoại này ("only off" để tắt)
  filters              Xem bộ lọc hiện tại
 Web xem tin: $(url)/view
H
    ;;
esac
CLI
chmod +x /usr/local/bin/zalo-backup

echo ">> npm install..."
npm install --omit=dev --no-audit --no-fund

# Tạo .env (giữ nguyên nếu đã có)
if [ ! -f .env ]; then
  PASS=$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')
  cat > .env <<ENV
PORT=$PORT
AUTH_USER=admin
AUTH_PASS=$PASS
ENV
  chmod 600 .env
fi
for kv in MEDIA_DAYS=10 TEXT_DAYS=0 COMPRESS_DAYS=30 MAX_FILE_MB=20 MIN_FREE_GB=2; do
  grep -q "^${kv%%=*}=" .env || echo "$kv" >> .env
done

echo ">> Tạo systemd service..."
cat > /etc/systemd/system/$SERVICE.service <<UNIT
[Unit]
Description=Zalo Backup Bot
After=network-online.target
Wants=network-online.target

[Service]
WorkingDirectory=$APP_DIR
EnvironmentFile=$APP_DIR/.env
ExecStart=$(command -v node) server.js
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now $SERVICE
systemctl restart $SERVICE
[ -f cred.json ] && chmod 600 cred.json || true

set -a; . ./.env; set +a
IP=$(curl -fsS https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')
echo
echo "=============================================="
echo " Cài xong!"
echo " Web:      http://$IP:$PORT   (xem tin: /view)"
echo " User:     $AUTH_USER"
echo " Password: $AUTH_PASS"
echo " Tin nhắn: $APP_DIR/backup/<threadId>/<ngày>.jsonl"
echo " Quản lý:  zalo-backup help"
echo "=============================================="
