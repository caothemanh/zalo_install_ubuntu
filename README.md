# Zalo Backup Bot

Đăng nhập Zalo bằng QR trên web, tự sao lưu tin nhắn đến/đi vào `/opt/zalo-backup/backup/`.

## Cài đặt (Ubuntu, 1 lệnh)

```bash
curl -fsSL https://raw.githubusercontent.com/caothemanh/zalo_install_ubuntu/main/install.sh | sudo bash
```

Cổng khác: `curl -fsSL ... | sudo PORT=8080 bash`

Script sẽ in ra URL + user/password. Mở URL, quét QR bằng Zalo.

## Gỡ
```bash
curl -fsSL https://raw.githubusercontent.com/USER/REPO/main/install.sh | sudo bash -s uninstall
```

> Dùng API không chính thức (zca-js), có rủi ro bị khóa tài khoản. Nên thử bằng nick phụ.
