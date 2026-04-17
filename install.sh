#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
#  NaïveProxy Manager — установщик короткой команды
#  Добавляет команду `naive` в /usr/local/bin
# ═══════════════════════════════════════════════════════════
set -euo pipefail

REPO="pumbaX/naiv"
BRANCH="main"
SCRIPT_NAME="NaiveProxy.sh"
INSTALL_PATH="/usr/local/bin/naive"

# Автоматически поднимаем права до root через sudo
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    echo "🔑 Требуются root-права, перезапускаю через sudo..."
    exec sudo bash -c "bash <(curl -fsSL https://raw.githubusercontent.com/${REPO}/${BRANCH}/install.sh)"
  else
    echo "❌ Запустите от root (sudo не установлен)"
    exit 1
  fi
fi

echo "📦 Устанавливаю команду 'naive'..."

cat > "$INSTALL_PATH" <<EOF
#!/usr/bin/env bash
# Обёртка для NaïveProxy Manager
# Скачивает скрипт во временный файл и запускает с прямым stdin

set -e

if [[ \${EUID:-\$(id -u)} -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    exec sudo bash "\$0" "\$@"
  else
    echo "❌ Запустите от root"
    exit 1
  fi
fi

TMP=\$(mktemp /tmp/naive.XXXXXX.sh)
trap 'rm -f "\$TMP"' EXIT

if ! curl -fsSL "https://raw.githubusercontent.com/${REPO}/${BRANCH}/${SCRIPT_NAME}" -o "\$TMP"; then
  echo "❌ Не удалось скачать скрипт"
  exit 1
fi

exec bash "\$TMP" "\$@"
EOF

chmod +x "$INSTALL_PATH"

echo "✔ Установлено в $INSTALL_PATH"
echo ""
echo "Теперь запускай одной командой:"
echo ""
echo "  naive"
echo ""
