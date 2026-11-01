# Zalo Backup Bot

Đăng nhập Zalo bằng QR trên web, tự sao lưu tin nhắn đến/đi vào `/opt/zalo-backup/backup/`.

## Cài đặt (Ubuntu, 1 lệnh)
```bash
curl -fsSL https://raw.githubusercontent.com/caothemanh/zalo_install_ubuntu/main/install.sh | sudo bash
```

Cổng khác: `curl -fsSL ... | sudo PORT=8080 bash`

Script sẽ in ra URL + user/password. Mở URL, quét QR bằng Zalo.

## Media
Ảnh, voice, video, file được tải về `backup/<threadId>/media/`, tự xóa sau 10 ngày. Tin chữ giữ vĩnh viễn.
Chỉnh trong `/opt/zalo-backup/.env` rồi `systemctl restart zalo-backup`:
`MEDIA_DAYS=10`, `MAX_FILE_MB=20`, `MIN_FREE_GB=2`.

## Tính năng
- Lưu tin đến/đi theo `backup/<threadId>/<ngày>.jsonl`; ảnh/voice/video/file vào `media/` (tự xóa sau 10 ngày).
- **Web xem tin** `http://IP:3000/view`: duyệt theo hội thoại/ngày, tìm kiếm không cần dấu, xem ảnh/nghe voice.
- **Bắt tin thu hồi**: tin đối phương thu hồi vẫn còn bản gốc, được đánh dấu 🗑.
- **Lọc hội thoại**: `ignore` / `only`, áp dụng ngay không cần restart.
- **Cảnh báo Telegram**: mất kết nối, cần quét QR lại, ổ đĩa sắp đầy.
- **Nén gzip** file tin chữ cũ hơn 30 ngày (vẫn tìm kiếm/xem bình thường).
- **Export** một hội thoại ra HTML + txt (kèm media còn lưu).

## Facebook Messenger (tùy chọn)
Chạy như dịch vụ riêng `zalo-backup-fb`, lưu chung thư mục (`backup/fb_<id>/`), xem chung trong web `/view` và app.
1. Đăng nhập facebook.com trên trình duyệt (nên dùng **nick phụ**), cài Cookie-Editor, Export → JSON.
2. Dán JSON vào trang `https://<máy chủ>/fb` (hoặc `zalo-backup fb appstate <file.json>`).
3. Kiểm tra: `zalo-backup fb status`.

Tin thu hồi được giữ lại và đánh dấu 🗑 như Zalo. **Giới hạn:** chat đã bật mã hóa đầu-cuối không đọc được;
đây là cách không chính thức nên Facebook có thể yêu cầu xác minh hoặc khóa tài khoản. Khi cookie hết hạn hoặc bị
checkpoint, dịch vụ tự dừng (không thử lại liên tục) và báo trạng thái ở `/fb`.

## Quản lý bằng terminal
```bash
zalo-backup help
zalo-backup status
zalo-backup days 10            # media 10 ngày (days 10 90: xóa cả tin chữ sau 90 ngày)
zalo-backup logout             # đăng xuất, quét QR tài khoản khác
zalo-backup threads            # danh sách hội thoại + dung lượng
zalo-backup search "từ khóa"   # không cần dấu
zalo-backup recalled           # tin bị thu hồi
zalo-backup ignore "tên nhóm"  # ngừng lưu nhóm này
zalo-backup only "Anh A" "Nhóm B"   # chỉ lưu các hội thoại này (only off để tắt)
zalo-backup export "Anh A" 2026-10-01 2026-10-31
zalo-backup telegram <bot_token> <chat_id>
zalo-backup set HOST 127.0.0.1 # chỉ cho truy cập nội bộ (dùng SSH tunnel)
zalo-backup update <link raw install.sh>
```

### Bật Telegram
1. Chat với @BotFather, `/newbot`, lấy **token**.
2. Nhắn `/start` cho bot vừa tạo, rồi lấy **chat id** (chat với @userinfobot).
3. `zalo-backup telegram <token> <chat_id>`.

> Web dùng HTTP + basic auth: mật khẩu và tin nhắn đi qua mạng không mã hóa. Nên dùng SSH tunnel
> (`zalo-backup set HOST 127.0.0.1` rồi `ssh -L 3000:127.0.0.1:3000 user@VPS`) hoặc đặt sau Nginx + HTTPS.

## Gỡ
```bash
curl -fsSL https://raw.githubusercontent.com/USER/REPO/main/install.sh | sudo bash -s uninstall
```

> Dùng API không chính thức (zca-js), có rủi ro bị khóa tài khoản. Nên thử bằng nick phụ.
