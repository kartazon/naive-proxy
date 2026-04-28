#!/usr/bin/env bash
# naiveproxy-watchdog-setup.sh — установщик мониторинга для NaïveProxy Manager
# Использование: bash naiveproxy-watchdog-setup.sh [install|remove|status|logs]
set -euo pipefail

# ═══════════════════════════════════════════════════════════
# КОНСТАНТЫ
# ═══════════════════════════════════════════════════════════
CADDY_CONFIG="/etc/caddy/Caddyfile"
MONITOR_LOG="/var/log/naiveproxy-watchdog.log"
MONITOR_STATE="/var/lib/naiveproxy/watchdog.state"
MONITOR_SCRIPT="/usr/local/bin/naiveproxy-watchdog.sh"
MONITOR_SERVICE="/etc/systemd/system/naiveproxy-watchdog.service"
MONITOR_TIMER="/etc/systemd/system/naiveproxy-watchdog.timer"
MONITOR_ALERT_SCRIPT="/etc/caddy/alert.sh"

# ═══════════════════════════════════════════════════════════
# HELPERS
# ═══════════════════════════════════════════════════════════
need_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "❌ Запустите от root"; exit 1; }
}

# ═══════════════════════════════════════════════════════════
# ГЕНЕРАЦИЯ WATCHDOG-СКРИПТА
# ═══════════════════════════════════════════════════════════
write_watchdog_script() {
  mkdir -p "$(dirname "$MONITOR_SCRIPT")"
  mkdir -p "$(dirname "$MONITOR_STATE")"
  mkdir -p "$(dirname "$MONITOR_LOG")"

  # Переменные с $ экранированы — они нужны в рантайме watchdog, не здесь
  cat > "$MONITOR_SCRIPT" << WATCHDOG
#!/usr/bin/env bash
# NaiveProxy Watchdog — автоматически запускается через systemd-timer
# Проверяет: caddy active, TCP/443, TLS expiry, HTTP probe resistance
set -euo pipefail

CONFIG="${CADDY_CONFIG}"
LOG="${MONITOR_LOG}"
STATE="${MONITOR_STATE}"
ALERT_SCRIPT="${MONITOR_ALERT_SCRIPT}"
MAX_LOG_LINES=5000

log()   { echo "\$(date '+%Y-%m-%d %H:%M:%S') \$*" | tee -a "\$LOG"; }
alert() {
  local msg="\$1"
  log "ALERT: \$msg"
  if [[ -f "\$ALERT_SCRIPT" ]]; then
    bash "\$ALERT_SCRIPT" "\$msg" 2>/dev/null || true
  else
    systemd-cat -t naiveproxy-watchdog -p err echo "\$msg" 2>/dev/null || true
  fi
}

# Ротация лога (держим не более MAX_LOG_LINES строк)
if [[ -f "\$LOG" ]]; then
  lines=\$(wc -l < "\$LOG" 2>/dev/null || echo 0)
  if [[ "\$lines" -gt "\$MAX_LOG_LINES" ]]; then
    tail -n 1000 "\$LOG" > "\${LOG}.tmp" && mv "\${LOG}.tmp" "\$LOG"
  fi
fi

mkdir -p "\$(dirname "\$STATE")"
errors=0
checks_ok=0
domain=""

# ── 1. Caddy active ───────────────────────────────────────
if ! systemctl is-active --quiet caddy 2>/dev/null; then
  alert "🔴 Caddy не активен — попытка перезапуска"
  systemctl start caddy 2>/dev/null \
    && log "✔ Caddy перезапущен" \
    || alert "❌ Caddy не удалось запустить"
  errors=\$((errors + 1))
else
  checks_ok=\$((checks_ok + 1))
fi

# ── 2. TCP/443 слушает ────────────────────────────────────
if ! ss -Hlnt 2>/dev/null | awk '{print \$4}' | grep -qE '[:.]443\$'; then
  alert "🔴 TCP/443 не слушает (caddy упал без уведомления systemd?)"
  errors=\$((errors + 1))
else
  checks_ok=\$((checks_ok + 1))
fi

# ── Парсим домен из Caddyfile ─────────────────────────────
if [[ -f "\$CONFIG" ]]; then
  domain=\$(awk '
    /:443/ {
      n = split(\$0, t, /[[:space:],{}]+/)
      for (i=1; i<=n; i++) {
        if (t[i]=="" || t[i]==":443" || t[i]~/^:/ || t[i]~/@/) continue
        if (t[i]~/\./ && t[i]!~/:/){ print t[i]; exit }
      }
    }
  ' "\$CONFIG")
fi

# ── 3. TLS cert expiry ────────────────────────────────────
if [[ -n "\${domain:-}" ]]; then
  tls_out=\$(timeout 8 openssl s_client \
    -connect "\${domain}:443" -servername "\$domain" \
    </dev/null 2>/dev/null \
    | openssl x509 -noout -enddate 2>/dev/null || true)

  if [[ -n "\$tls_out" ]]; then
    expiry_str=\$(echo "\$tls_out" | cut -d= -f2)
    expiry_epoch=\$(date -d "\$expiry_str" +%s 2>/dev/null || echo 0)
    now_epoch=\$(date +%s)
    days_left=\$(( (expiry_epoch - now_epoch) / 86400 ))

    if [[ "\$days_left" -le 7 ]]; then
      alert "🔴 TLS истекает через \${days_left}д! (\$domain)"
      errors=\$((errors + 1))
    elif [[ "\$days_left" -le 14 ]]; then
      log "🟡 TLS истекает через \${days_left}д (\$domain)"
      checks_ok=\$((checks_ok + 1))
    else
      log "✔ TLS OK: \$domain, осталось \${days_left}д"
      checks_ok=\$((checks_ok + 1))
    fi
  else
    log "🟡 Не удалось получить TLS данные от \${domain:-?} (нет сети?)"
  fi
fi

# ── 4. Probe resistance — HTTP 200 без auth ───────────────
if [[ -n "\${domain:-}" ]]; then
  http_code=\$(timeout 8 curl -s -o /dev/null -w "%{http_code}" \
    "https://\${domain}/" 2>/dev/null || echo "000")
  case "\$http_code" in
    200) checks_ok=\$((checks_ok + 1)) ;;
    000) log "🟡 Нет ответа от \$domain (фаерволл или нет сети)" ;;
    *)   alert "🔴 Probe: HTTP \$http_code (ожидалось 200, \$domain)"
         errors=\$((errors + 1)) ;;
  esac
fi

# ── Запись state-файла ────────────────────────────────────
if [[ "\$errors" -eq 0 ]]; then
  echo "ok \$(date +%s)" > "\$STATE"
  log "✔ Watchdog OK (\${checks_ok} проверок)"
else
  echo "err \$(date +%s) \$errors" > "\$STATE"
  log "❌ Watchdog: ошибок=\$errors, OK=\$checks_ok"
fi
WATCHDOG

  chmod 750 "$MONITOR_SCRIPT"
  echo "  ✔ Watchdog-скрипт: $MONITOR_SCRIPT"
}

# ═══════════════════════════════════════════════════════════
# ГЕНЕРАЦИЯ SYSTEMD UNITS
# ═══════════════════════════════════════════════════════════
write_monitor_units() {
  cat > "$MONITOR_SERVICE" << 'UNIT'
[Unit]
Description=NaiveProxy Watchdog (health check)
After=network-online.target caddy.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/naiveproxy-watchdog.sh
StandardOutput=journal
StandardError=journal
SyslogIdentifier=naiveproxy-watchdog
SuccessExitStatus=0 1
UNIT

  cat > "$MONITOR_TIMER" << 'TIMER'
[Unit]
Description=NaiveProxy Watchdog Timer
Requires=naiveproxy-watchdog.service

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=30s
Persistent=true

[Install]
WantedBy=timers.target
TIMER

  systemctl daemon-reload
  echo "  ✔ Systemd units записаны"
}

# ═══════════════════════════════════════════════════════════
# НАСТРОЙКА TELEGRAM-АЛЕРТОВ (опционально)
# ═══════════════════════════════════════════════════════════
setup_telegram_alert() {
  echo ""
  echo "  📨 Telegram-уведомления (опционально)"
  echo "  Нужен Bot Token (@BotFather → /newbot) и Chat ID."
  echo ""
  read -rp "  Настроить Telegram? (y/n): " yn
  [[ "$yn" == "y" ]] || return 0

  local token chat_id
  read -rp "  Bot Token: " token
  [[ -n "$token" ]] || { echo "  ⚠️  Пустой токен, пропуск"; return 0; }
  read -rp "  Chat ID:   " chat_id
  [[ -n "$chat_id" ]] || { echo "  ⚠️  Пустой chat_id, пропуск"; return 0; }

  local ok
  ok="$(curl -fsSL --connect-timeout 5 \
    "https://api.telegram.org/bot${token}/getMe" 2>/dev/null \
    | grep -o '"ok":true' || echo '')"
  [[ -n "$ok" ]] \
    && echo "  ✔ Токен валиден" \
    || echo "  ⚠️  Проверить токен не удалось (всё равно сохраним)"

  local hostname_str
  hostname_str="$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo 'unknown')"

  # Токен — только в alert.sh с правами 600, не в watchdog-скрипте
  cat > "$MONITOR_ALERT_SCRIPT" << ALERT
#!/usr/bin/env bash
TOKEN="${token}"
CHAT_ID="${chat_id}"
HOST="${hostname_str}"
MSG="[NaïveProxy @ \$HOST] \${1:-Alert}"
curl -fsSL --connect-timeout 10 \
  "https://api.telegram.org/bot\${TOKEN}/sendMessage" \
  --data-urlencode "chat_id=\${CHAT_ID}" \
  --data-urlencode "text=\${MSG}" \
  >/dev/null 2>&1 || true
ALERT

  chmod 600 "$MONITOR_ALERT_SCRIPT"
  echo "  ✔ Telegram alert: $MONITOR_ALERT_SCRIPT"
}

# ═══════════════════════════════════════════════════════════
# КОМАНДЫ
# ═══════════════════════════════════════════════════════════
cmd_install() {
  [[ -f "$CADDY_CONFIG" ]] || {
    echo "❌ NaiveProxy не установлен (нет $CADDY_CONFIG)"
    exit 1
  }

  echo ""
  echo "  ╔══════════════════════════════════════════╗"
  echo "  ║    NaïveProxy Watchdog — Установка       ║"
  echo "  ╚══════════════════════════════════════════╝"
  echo "  • Проверка каждые 5 минут"
  echo "  • Авто-перезапуск Caddy при падении"
  echo "  • TLS-алерт за 7 и 14 дней до истечения"
  echo "  • Лог: $MONITOR_LOG"
  echo ""

  setup_telegram_alert
  write_watchdog_script
  write_monitor_units

  systemctl enable --now naiveproxy-watchdog.timer
  # Первый прогон немедленно
  systemctl start naiveproxy-watchdog.service 2>/dev/null || true

  echo ""
  echo "  ══════════════════════════════════════════"
  echo "  ✔ Мониторинг активирован"
  echo ""
  echo "  Статус:  systemctl status naiveproxy-watchdog.timer"
  echo "  Логи:    journalctl -u naiveproxy-watchdog -f"
  echo "  Файл:    $MONITOR_LOG"
  echo "  ══════════════════════════════════════════"
}

cmd_remove() {
  echo ""
  read -rp "  ⚠️  Удалить watchdog-мониторинг? (y/n): " yn
  [[ "$yn" == "y" ]] || { echo "Отмена"; exit 0; }

  systemctl stop    naiveproxy-watchdog.timer   2>/dev/null || true
  systemctl disable naiveproxy-watchdog.timer   2>/dev/null || true
  systemctl stop    naiveproxy-watchdog.service 2>/dev/null || true
  rm -f "$MONITOR_SERVICE" "$MONITOR_TIMER" "$MONITOR_SCRIPT"
  systemctl daemon-reload

  echo "  ✔ Мониторинг удалён"
  echo "  Лог сохранён:         $MONITOR_LOG"
  echo "  Alert-скрипт сохранён: $MONITOR_ALERT_SCRIPT"
}

cmd_status() {
  echo ""
  echo "  ── Статус мониторинга ────────────────────"

  if systemctl is-active --quiet naiveproxy-watchdog.timer 2>/dev/null; then
    echo "  🟢 Timer активен"
    systemctl status naiveproxy-watchdog.timer --no-pager 2>&1 | grep -E 'Trigger:|Active:' | sed 's/^/  /'
  else
    echo "  🔴 Timer не активен"
  fi

  if [[ -f "$MONITOR_STATE" ]]; then
    local sw epoch_ts human_ts
    sw="$(awk '{print $1}' "$MONITOR_STATE" 2>/dev/null)"
    epoch_ts="$(awk '{print $2}' "$MONITOR_STATE" 2>/dev/null)"
    human_ts="$(date -d "@${epoch_ts}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo '?')"
    if [[ "$sw" == "ok" ]]; then
      echo "  ✔ Последняя проверка: $human_ts — OK"
    else
      local nerr
      nerr="$(awk '{print $3}' "$MONITOR_STATE" 2>/dev/null)"
      echo "  ❌ Последняя проверка: $human_ts — ошибок: ${nerr:-?}"
    fi
  else
    echo "  ⚪ State-файл не найден (проверка ещё не запускалась)"
  fi

  if [[ -f "$MONITOR_ALERT_SCRIPT" ]]; then
    echo "  📨 Telegram-алерт:    настроен ($MONITOR_ALERT_SCRIPT)"
  else
    echo "  📭 Telegram-алерт:    не настроен"
  fi
  echo ""
}

cmd_logs() {
  echo "  Ctrl+C для выхода"
  echo ""
  journalctl -u naiveproxy-watchdog -f --no-pager
}

# ═══════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════
need_root

case "${1:-menu}" in
  install) cmd_install ;;
  remove)  cmd_remove  ;;
  status)  cmd_status  ;;
  logs)    cmd_logs    ;;
  menu|*)
    echo ""
    echo "  ╔══════════════════════════════════════════╗"
    echo "  ║    NaïveProxy Watchdog Manager           ║"
    echo "  ╚══════════════════════════════════════════╝"
    cmd_status
    echo "  1) Установить / переустановить мониторинг"
    echo "  2) Удалить мониторинг"
    echo "  3) Логи (live)"
    echo "  0) Выход"
    echo ""
    read -rp "  Выбор: " choice
    case "$choice" in
      1) cmd_install ;;
      2) cmd_remove  ;;
      3) cmd_logs    ;;
      0) exit 0      ;;
      *) echo "❌ Неверный выбор" ;;
    esac
    ;;
esac
