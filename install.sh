#!/usr/bin/env bash
#
# install.sh — ставит команду `relabel` в PATH (симлинк на relabel.sh).
# После этого скрипт можно вызывать из любого каталога: `relabel apply`.
#
# Конфиг (names.conf) и состояние (.state/) остаются в каталоге репозитория —
# симлинк на них не влияет.
#
set -euo pipefail

REPO_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$REPO_DIR/relabel.sh"
NAME="relabel"

# Каталог в PATH: /usr/local/bin (обычно есть в PATH у root).
BIN_DIR="${PREFIX:-/usr/local/bin}"

[ -f "$TARGET" ] || { echo "Не нашёл $TARGET" >&2; exit 1; }
chmod +x "$TARGET"

LINK="$BIN_DIR/$NAME"

SUDO=""
if [ ! -w "$BIN_DIR" ]; then
  if command -v sudo >/dev/null 2>&1; then SUDO="sudo"; else
    echo "Нет прав на запись в $BIN_DIR и нет sudo. Запустите от root или задайте PREFIX." >&2
    exit 1
  fi
fi

$SUDO ln -sf "$TARGET" "$LINK"

echo "Установлено: $LINK -> $TARGET"
echo "Теперь доступно из любого места:"
echo "  relabel status"
echo "  relabel apply"
echo "  relabel restore"

if ! command -v "$NAME" >/dev/null 2>&1; then
  echo
  echo "Внимание: $BIN_DIR не в PATH. Добавьте в ~/.bashrc:"
  echo "  export PATH=\"$BIN_DIR:\$PATH\""
fi

# Удаление:  $SUDO rm -f $LINK
