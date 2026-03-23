#!/bin/bash
set -e

# ─────────────────────────────────────────────
#  GlobalShield Gateway — Установка
# ─────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[GSG]${NC} $1"; }
success() { echo -e "${GREEN}[✓]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
error()   { echo -e "${RED}[✗]${NC} $1"; exit 1; }

REPO_URL="https://github.com/SanSanichSan/gsg.git"
INSTALL_DIR="/root/GSG"

echo ""
echo -e "${CYAN}  GlobalShield Gateway — Установщик${NC}"
echo -e "  ──────────────────────────────────"
echo ""

# Проверка root
[ "$(id -u)" -ne 0 ] && error "Запустите скрипт от root: sudo bash install.sh"

# Зависимости
info "Проверка зависимостей..."
MISSING=()
for cmd in git docker curl; do
    command -v "$cmd" &>/dev/null || MISSING+=("$cmd")
done

if [ ${#MISSING[@]} -gt 0 ]; then
    info "Устанавливаем: ${MISSING[*]}"
    apt-get update -qq
    apt-get install -y -qq "${MISSING[@]}"
fi

# Docker Compose plugin
if ! docker compose version &>/dev/null 2>&1; then
    info "Устанавливаем Docker Compose plugin..."
    apt-get install -y -qq docker-compose-plugin 2>/dev/null || \
    curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" \
        -o /usr/local/lib/docker/cli-plugins/docker-compose && \
    chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
fi

success "Зависимости установлены"

# Клонирование / обновление
if [ -d "$INSTALL_DIR/.git" ]; then
    info "Обновление существующей установки..."
    git -C "$INSTALL_DIR" pull --ff-only
else
    info "Клонирование репозитория..."
    git clone "$REPO_URL" "$INSTALL_DIR"
fi

cd "$INSTALL_DIR"

# ── Конфигурация ──────────────────────────────
echo ""
echo -e "${CYAN}  Настройка сети${NC}"
echo ""

# Определяем текущий IP
DETECTED_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
read -rp "  IP шлюза (Gateway IP) [${DETECTED_IP:-10.10.1.1}]: " GATEWAY_IP
GATEWAY_IP="${GATEWAY_IP:-${DETECTED_IP:-10.10.1.1}}"

# Определяем LAN-интерфейс
DETECTED_IFACE=$(ip route | awk '/default/{print $5}' | head -1)
read -rp "  LAN-интерфейс [${DETECTED_IFACE:-eth0}]: " LAN_IFACE
LAN_IFACE="${LAN_IFACE:-${DETECTED_IFACE:-eth0}}"

SUBNET_PREFIX=$(echo "$GATEWAY_IP" | cut -d. -f1-3)
DEFAULT_START="${SUBNET_PREFIX}.100"
DEFAULT_END="${SUBNET_PREFIX}.200"

read -rp "  DHCP пул начало [${DEFAULT_START}]: " DHCP_START
DHCP_START="${DHCP_START:-$DEFAULT_START}"

read -rp "  DHCP пул конец [${DEFAULT_END}]: " DHCP_END
DHCP_END="${DHCP_END:-$DEFAULT_END}"

echo ""

# Записываем .env
cat > "$INSTALL_DIR/.env" <<EOF
GSG_GATEWAY_IP=${GATEWAY_IP}
GSG_LAN_INTERFACE=${LAN_IFACE}
GSG_DHCP_START=${DHCP_START}
GSG_DHCP_END=${DHCP_END}
GSG_TPROXY_PORT=12345
EOF

# Подставляем IP в docker-compose.yml
sed -i "s/GSG_GATEWAY_IP=.*/GSG_GATEWAY_IP=${GATEWAY_IP}/" docker-compose.yml
sed -i "s/GSG_LAN_INTERFACE=.*/GSG_LAN_INTERFACE=${LAN_IFACE}/" docker-compose.yml
sed -i "s/GSG_DHCP_START=.*/GSG_DHCP_START=${DHCP_START}/" docker-compose.yml
sed -i "s/GSG_DHCP_END=.*/GSG_DHCP_END=${DHCP_END}/" docker-compose.yml

success "Конфиг записан (.env + docker-compose.yml)"

# ── Watchdog ──────────────────────────────────
if [ -e /dev/watchdog ]; then
    info "Настройка hardware watchdog..."
    if ! grep -q "^RuntimeWatchdogSec=" /etc/systemd/system.conf 2>/dev/null; then
        sed -i 's/#RuntimeWatchdogSec=0/RuntimeWatchdogSec=15/' /etc/systemd/system.conf 2>/dev/null || \
        echo "RuntimeWatchdogSec=15" >> /etc/systemd/system.conf
        sed -i 's/#WatchdogDevice=/WatchdogDevice=\/dev\/watchdog/' /etc/systemd/system.conf 2>/dev/null || \
        echo "WatchdogDevice=/dev/watchdog" >> /etc/systemd/system.conf
        systemctl daemon-reexec 2>/dev/null || true
    fi
    success "Watchdog настроен (/dev/watchdog, 15 сек)"
else
    warn "Hardware watchdog не найден — пропускаем"
fi

# ── IP Forwarding ─────────────────────────────
info "Включение IP forwarding..."
echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-gsg.conf
sysctl -p /etc/sysctl.d/99-gsg.conf -q
success "IP forwarding включён"

# ── Сборка и запуск ───────────────────────────
echo ""
info "Сборка Docker образов (может занять несколько минут)..."
docker compose build

info "Запуск контейнеров..."
docker compose up -d

echo ""
success "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
success "  GSG установлен и запущен!"
echo ""
echo -e "  Веб-интерфейс: ${CYAN}http://${GATEWAY_IP}:8080${NC}"
echo ""
echo -e "  Для проверки статуса:"
echo -e "  ${YELLOW}docker compose -f ${INSTALL_DIR}/docker-compose.yml ps${NC}"
echo ""
