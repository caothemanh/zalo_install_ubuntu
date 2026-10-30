#!/bin/bash

# ==========================================
# AUTO INSTALL ZALO WEB ON VPS VIA DOCKER
# ==========================================

# Màu sắc thông báo
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}===============================================${NC}"
echo -e "${GREEN}   Bắt đầu cài đặt Zalo Web 24/7 trên VPS     ${NC}"
echo -e "${GREEN}===============================================${NC}"

# 1. Cập nhật hệ thống
echo -e "${YELLOW}[1/5] Cập nhật danh sách gói hệ thống...${NC}"
sudo apt update -y

# 2. Kiểm tra và Cài đặt Docker
if ! command -v docker &> /dev/null; then
    echo -e "${YELLOW}[2/5] Chưa phát hiện Docker. Đang tiến hành cài đặt Docker...${NC}"
    curl -fsSL https://get.docker.com -o get-docker.sh
    sudo sh get-docker.sh
    rm get-docker.sh
else
    echo -e "${GREEN}[2/5] Docker đã được cài đặt sẵn.${NC}"
fi

# 3. Tạo thư mục dữ liệu
echo -e "${YELLOW}[3/5] Khởi tạo thư mục lưu trữ dữ liệu Zalo...${NC}"
DATA_DIR="$HOME/zalo-data"
BACKUP_DIR="$HOME/zalo-backups"

mkdir -p "$DATA_DIR/profile"
mkdir -p "$DATA_DIR/downloads"
mkdir -p "$BACKUP_DIR"

# 4. Nhập mật khẩu VNC & Port
echo -e "${GREEN}-----------------------------------------------${NC}"
read -p "Nhập mật khẩu truy cập WebGUI (mặc định: zalo123456): " VNC_PW
VNC_PW=${VNC_PW:-zalo123456}

read -p "Nhập Cổng (Port) truy cập WebGUI (mặc định: 6901): " PORT
PORT=${PORT:-6901}

# Dừng container cũ nếu tồn tại
if [ $(docker ps -aq -f name=zalo-web) ]; then
    echo -e "${YELLOW}Đang dừng và xóa container zalo-web cũ...${NC}"
    docker stop zalo-web >/dev/null 2>&1
    docker rm zalo-web >/dev/null 2>&1
fi

# Chạy Docker Container
echo -e "${YELLOW}[4/5] Đang khởi chạy Docker Container Zalo Web...${NC}"
docker run -d \
  --name zalo-web \
  --restart unless-stopped \
  -p ${PORT}:6901 \
  -e VNC_PW="${VNC_PW}" \
  -v "${DATA_DIR}/profile":/home/kasm-user/.config/google-chrome \
  -v "${DATA_DIR}/downloads":/home/kasm-user/Downloads \
  --shm-size=2g \
  kasmweb/chrome:1.14.0

# 5. Cấu hình tự động Sao lưu (Backup Cronjob)
echo -e "${YELLOW}[5/5] Thiết lập Cronjob tự động backup dữ liệu vào 02:00 sáng...${NC}"
BACKUP_SCRIPT="$HOME/backup_zalo.sh"

cat << 'EOF' > "$BACKUP_SCRIPT"
#!/bin/bash
BACKUP_DIR="$HOME/zalo-backups"
DATA_DIR="$HOME/zalo-data"
DATE=$(date +%Y-%m-%d_%H%M%S)

mkdir -p "$BACKUP_DIR"
tar -czf "$BACKUP_DIR/zalo_session_$DATE.tar.gz" -C "$DATA_DIR" profile
find "$BACKUP_DIR" -type f -mtime +7 -name "*.tar.gz" -delete
EOF

chmod +x "$BACKUP_SCRIPT"

# Thêm Cronjob nếu chưa có
(crontab -l 2>/dev/null | grep -v "$BACKUP_SCRIPT"; echo "0 2 * * * $BACKUP_SCRIPT") | crontab -

# Lấy IP Public của VPS
SERVER_IP=$(curl -s https://api.ipify.org || hostname -I | awk '{print $1}')

echo -e "${GREEN}===============================================${NC}"
echo -e "${GREEN}         CÀI ĐẶT HOÀN TẤT THÀNH CÔNG!          ${NC}"
echo -e "${GREEN}===============================================${NC}"
echo -e "Truy cập giao diện Zalo Web tại:"
echo -e "${YELLOW}👉 https://${SERVER_IP}:${PORT}${NC}"
echo -e ""
echo -e "Thông tin đăng nhập WebGUI:"
echo -e "  - Username: ${GREEN}kasm_user${NC}"
echo -e "  - Password: ${GREEN}${VNC_PW}${NC}"
echo -e ""
echo -e "Thư mục sao lưu tin nhắn/session: ${YELLOW}${BACKUP_DIR}${NC}"
echo -e "${GREEN}===============================================${NC}"
