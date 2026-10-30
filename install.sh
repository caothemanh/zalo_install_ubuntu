#!/usr/bin/env bash
# Zalo Backup Bot - cài đặt 1 lệnh trên Ubuntu
# Dùng:   curl -fsSL https://raw.githubusercontent.com/USER/REPO/main/install.sh | sudo bash
# Gỡ:     curl -fsSL .../install.sh | sudo bash -s uninstall
set -euo pipefail

APP_DIR=/opt/zalo-backup
SERVICE=zalo-backup
PORT="${PORT:-3000}"

[ "$(id -u)" -eq 0 ] || { echo "Chạy bằng root: sudo bash install.sh"; exit 1; }

if [ "${1:-}" = "uninstall" ]; then
  systemctl disable --now $SERVICE 2>/dev/null || true
  rm -f /etc/systemd/system/$SERVICE.service
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
  "version": "1.0.0",
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

const BACKUP_DIR = process.env.BACKUP_DIR || "./backup";
const CRED = "./cred.json";
const PORT = process.env.PORT || 3000;
const AUTH_USER = process.env.AUTH_USER;
const AUTH_PASS = process.env.AUTH_PASS;
fs.mkdirSync(BACKUP_DIR, { recursive: true });

let qrImage = null, status = "init";

// Web server chạy trước để quét QR
const app = express();
app.use((req, res, next) => {
  const h = req.headers.authorization || "";
  const dec = Buffer.from(h.slice(6), "base64").toString();
  const i = dec.indexOf(":");
  if (AUTH_USER && dec.slice(0, i) === AUTH_USER && dec.slice(i + 1) === AUTH_PASS) return next();
  res.set("WWW-Authenticate", 'Basic realm="zalo"').status(401).end();
});
app.get("/", (_, res) => res.send(
  `<meta name=viewport content="width=device-width"><meta http-equiv=refresh content=3>` +
  `<h3>Trạng thái: ${status}</h3>` +
  (qrImage ? `<img src="${qrImage.startsWith("data:") ? qrImage : "data:image/png;base64," + qrImage}">` : "")));
app.listen(PORT, () => console.log("Web: http://IP:" + PORT));

const zalo = new Zalo({ selfListen: true });

async function login() {
  if (fs.existsSync(CRED)) {
    try { return await zalo.login(JSON.parse(fs.readFileSync(CRED))); }
    catch { console.log("Cred hết hạn, quét QR lại"); }
  }
  return await zalo.loginQR({}, (e) => {
    switch (e.type) {
      case LoginQRCallbackEventType.QRCodeGenerated:
        qrImage = e.data.image; status = "Quét QR bằng app Zalo"; break;
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

const api = await login();
status = "Online - đang sao lưu"; qrImage = null;

api.listener.on("message", (m) => {
  const d = {
    time: new Date().toISOString(),
    threadId: m.threadId,
    type: m.type,
    isSelf: m.isSelf,
    msgId: m.data.msgId,
    from: m.data.uidFrom,
    name: m.data.dName,
    content: m.data.content,
    ts: m.data.ts,
  };
  const dir = path.join(BACKUP_DIR, String(m.threadId));
  fs.mkdirSync(dir, { recursive: true });
  fs.appendFileSync(path.join(dir, d.time.slice(0, 10) + ".jsonl"), JSON.stringify(d) + "\n");
});
api.listener.on("closed", (code) => { console.log("closed", code); process.exit(1); });
api.listener.on("error", (e) => console.error("listener error", e));
api.listener.start();
JS

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
  NEWPASS=1
fi

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
[ -f cred.json ] && chmod 600 cred.json || true

. ./.env
IP=$(curl -fsS https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')
echo
echo "=============================================="
echo " Cài xong!"
echo " Web:      http://$IP:$PORT"
echo " User:     $AUTH_USER"
echo " Password: $AUTH_PASS"
echo " Tin nhắn: $APP_DIR/backup/<threadId>/<ngày>.jsonl"
echo " Log:      journalctl -u $SERVICE -f"
echo " Gỡ:       sudo bash install.sh uninstall"
echo "=============================================="
