#!/usr/bin/env bash
# Universal, conservative VPS baseline for Ubuntu 22.04/24.04.
# Run as root. Review before use; UFW activation is explicitly optional.

set -Eeuo pipefail
umask 077

LOG="/var/log/vps-optimization.log"
exec > >(tee -a "$LOG") 2>&1

say()  { printf '\n[%s] %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '\n[WARNING] %s\n' "$*" >&2; }
die()  { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Запусти скрипт от root: sudo bash $0"
command -v apt-get >/dev/null 2>&1 || die "Этот скрипт предназначен для Ubuntu/Debian с apt."
. /etc/os-release
[[ "${ID:-}" == "ubuntu" || "${ID_LIKE:-}" == *"debian"* ]] || die "Поддерживаются Ubuntu и Debian-подобные системы."
[[ "${VERSION_ID:-}" == "22.04" || "${VERSION_ID:-}" == "24.04" || "${ID:-}" == "debian" ]] || warn "Версия ОС не проверялась. Продолжаю с консервативными настройками."

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/vps-optimization-backup-$STAMP"
mkdir -p "$BACKUP"
say "Резервная копия изменяемых файлов: $BACKUP"

backup_file() {
  local f="$1"
  if [[ -e "$f" ]]; then
    mkdir -p "$BACKUP$(dirname "$f")"
    cp -a "$f" "$BACKUP$f"
  fi
}

say "Сбор исходной информации"
printf 'OS: %s %s\n' "${PRETTY_NAME:-unknown}" "${VERSION_ID:-}"
printf 'Kernel: %s\n' "$(uname -r)"
printf 'CPU: %s vCPU\n' "$(nproc)"
printf 'RAM: %s\n' "$(free -h | awk '/^Mem:/ {print $2}')"
printf 'Disk: %s свободно в /\n' "$(df -hP / | awk 'NR==2 {print $4}')"

say "Обновление списка пакетов и установка базовых инструментов"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl jq unattended-upgrades fail2ban ufw

say "Настройка безопасных системных параметров"
SYSCTL_FILE="/etc/sysctl.d/99-vps-baseline.conf"
backup_file "$SYSCTL_FILE"
cat > "$SYSCTL_FILE" <<'EOF'
# Conservative baseline. No aggressive buffer or queue tuning.
fs.file-max = 1048576
net.core.somaxconn = 2048
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_fin_timeout = 20
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.ip_local_port_range = 10240 65535
vm.swappiness = 10
EOF

# Enable BBR only when the running kernel explicitly reports support.
AVAILABLE_CC="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
if grep -qw bbr <<< "$AVAILABLE_CC"; then
  cat >> "$SYSCTL_FILE" <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
  say "BBR поддерживается ядром: включаю BBR + fq."
else
  say "BBR не обнаружен в текущем ядре: оставляю штатный алгоритм TCP."
fi

sysctl --system

say "Настройка системных лимитов"
LIMITS_FILE="/etc/security/limits.d/99-vps-baseline.conf"
backup_file "$LIMITS_FILE"
cat > "$LIMITS_FILE" <<'EOF'
* soft nofile 65535
* hard nofile 65535
root soft nofile 65535
root hard nofile 65535
EOF

SYSTEMD_DROPIN="/etc/systemd/system.conf.d/99-vps-baseline.conf"
backup_file "$SYSTEMD_DROPIN"
mkdir -p /etc/systemd/system.conf.d
cat > "$SYSTEMD_DROPIN" <<'EOF'
[Manager]
DefaultLimitNOFILE=65535
EOF
systemctl daemon-reexec

say "Настройка journald: ограничение размера системных журналов"
JOURNAL_FILE="/etc/systemd/journald.conf.d/99-vps-baseline.conf"
backup_file "$JOURNAL_FILE"
mkdir -p /etc/systemd/journald.conf.d
cat > "$JOURNAL_FILE" <<'EOF'
[Journal]
SystemMaxUse=500M
SystemMaxFileSize=50M
MaxRetentionSec=14day
EOF
systemctl restart systemd-journald

say "Настройка Fail2ban для SSH"
JAIL_FILE="/etc/fail2ban/jail.d/99-vps-sshd.local"
backup_file "$JAIL_FILE"
mkdir -p /etc/fail2ban/jail.d
cat > "$JAIL_FILE" <<'EOF'
[sshd]
enabled = true
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
EOF
systemctl enable --now fail2ban
systemctl restart fail2ban

say "Настройка автоматической установки обновлений безопасности"
AUTO_FILE="/etc/apt/apt.conf.d/20auto-upgrades"
backup_file "$AUTO_FILE"
cat > "$AUTO_FILE" <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
systemctl enable --now unattended-upgrades 2>/dev/null || true

say "Проверка Swap"
if ! swapon --show --noheadings | grep -q .; then
  RAM_KB="$(awk '/MemTotal:/ {print $2}' /proc/meminfo)"
  FREE_KB="$(df -Pk / | awk 'NR==2 {print $4}')"
  if (( RAM_KB <= 2097152 && FREE_KB >= 2097152 )); then
    read -r -p "Обнаружено RAM до 2 ГБ. Создать файл подкачки 1 ГБ? [y/N]: " MAKE_SWAP
    if [[ "$MAKE_SWAP" =~ ^[YyДд]$ ]]; then
      if ! fallocate -l 1G /swapfile 2>/dev/null; then
        dd if=/dev/zero of=/swapfile bs=1M count=1024 status=progress
      fi
      chmod 600 /swapfile
      mkswap /swapfile
      swapon /swapfile
      grep -qE '^/swapfile[[:space:]]' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
      say "Swap 1 ГБ создан и добавлен в /etc/fstab."
    else
      say "Создание Swap пропущено."
    fi
  else
    say "Swap не создаю автоматически: объём RAM/свободного диска не требует этого."
  fi
else
  say "Swap уже настроен, не изменяю."
fi

say "Настройка UFW без автоматического включения"
# Determine the actual SSH listening port before adding an allow rule.
SSH_PORT="22"
if command -v sshd >/dev/null 2>&1; then
  DETECTED_PORT="$(sshd -T 2>/dev/null | awk '$1=="port" {print $2; exit}')"
  [[ "$DETECTED_PORT" =~ ^[0-9]+$ ]] && SSH_PORT="$DETECTED_PORT"
fi
ufw allow "${SSH_PORT}/tcp" comment 'SSH access' || true
ufw default deny incoming
ufw default allow outgoing
ufw status verbose || true

cat <<EOF

UFW подготовлен. SSH-порт ${SSH_PORT}/tcp разрешён.
ВНИМАНИЕ: включение UFW может закрыть доступ к другим сервисам
(например, панели, VPN, DNS, веб-серверу), если их порты не разрешены.
EOF
read -r -p "Включить UFW сейчас? Сначала добавь правила для всех нужных портов. [y/N]: " ENABLE_UFW
if [[ "$ENABLE_UFW" =~ ^[YyДд]$ ]]; then
  ufw --force enable
  say "UFW включён."
else
  say "UFW оставлен выключенным. Правило SSH уже добавлено."
fi

say "Проверка состояния"
systemctl is-active --quiet fail2ban && echo "Fail2ban: active" || warn "Fail2ban не активен."
systemctl is-active --quiet systemd-journald && echo "journald: active" || warn "journald не активен."
echo
echo "TCP congestion control: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
echo "Open files limit (current shell): $(ulimit -n)"
echo "Swap:"
swapon --show || true
echo
echo "UFW:"
ufw status verbose || true

say "Готово. Резервные копии: $BACKUP"
echo "Лог выполнения: $LOG"
echo "Перезагрузка не выполнялась. Если обновлялось ядро, запланируй перезагрузку отдельно."
