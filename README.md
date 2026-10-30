# Zalo Web 24/7 on VPS via Docker

Giải pháp chạy Zalo Web liên tục 24/7 trên VPS Ubuntu/Debian thông qua Docker Chrome WebGUI, hỗ trợ tự động sao lưu dữ liệu và tin nhắn hàng ngày.

## 🚀 Tính năng chính
- Running Chrome WebGUI trên Docker container.
- Tự động duy trì đăng nhập Zalo Web 24/7.
- Tự động cài đặt Docker và cấu hình môi trường.
- Tích hợp Cronjob sao lưu (backup) profile Zalo Web mỗi ngày lúc 02:00 AM.
- Tự động dọn dẹp các bản backup cũ quá 7 ngày.

## 🛠 Hướng dẫn sử dụng

Chạy duy nhất **1 lệnh** sau trên VPS Ubuntu/Debian của bạn:

```bash
bash <(curl -sSL https://raw.githubusercontent.com/<username>/<repo-name>/main/install.sh)
```
*(Thay `<username>` và `<repo-name>` bằng tài khoản GitHub & tên Repository của bạn)*

## 📂 Structure Repository

- `install.sh`: Script cài đặt chính.
- `README.md`: Tài liệu hướng dẫn sử dụng.
