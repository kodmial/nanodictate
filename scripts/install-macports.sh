#!/bin/bash
#
# install-macports.sh — Вариант D: канон установки NanoDictate через MacPorts.
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/kodmial/nanodictate/main/scripts/install-macports.sh)
#
# Идемпотентный установщик: одна и та же команда работает и как первая
# установка на чистой машине, и как восстановление после переустановки
# MacPorts. Никакого Xcode / Swift toolchain не нужно — ставится готовый
# бинарный тарбол с GitHub Releases (тот же, что в Homebrew).
#
# Шаги:
#   1. перевызывает себя под sudo (обычный запрос пароля; при NOPASSWD — без);
#   2. клонирует канон-дерево kodmial/macports-nanodictate в
#      /Users/Shared/macports-nanodictate (если его ещё нет) и отдаёт root:admin
#      (git >= 2.35.2 отказывается тянуть дерево с чужим владельцем);
#   3. прописывает строку "file://..." в эффективный sources.conf — по
#      умолчанию /opt/local/etc/macports/sources.conf. Если в
#      ~/.macports/macports.conf задан sources_conf, правится пользовательский
#      файл (он имеет приоритет над системным). Строка вставляется ПЕРЕД
#      [default] — первое совпадение побеждает, наше дерево затеняет
#      rsync-источник; если [default] нет — дописывается в конец.
#   4. обновляет индекс канон-дерева (portindex);
#   5. port install nanodictate — post-activate сразу регистрирует и запускает
#      глобальную службу com.nanodictate.agent (launchd), Alt+Alt работает
#      сразу после установки.
#
# Переменные окружения (для тестов/E2E):
#   NANODICTATE_TREE=...       — путь к канон-дереву
#                                (по умолчанию /Users/Shared/macports-nanodictate)
#   NANODICTATE_SKIP_INSTALL=1 — пропустить `port install`
#                                (только clone + sources.conf + portindex)
#   NANODICTATE_STAGE=...      — (внутренняя; curl-запуск) путь временного
#                                установщика; удаляется на выходе root-процесса

set -euo pipefail

SCRIPT_URL="https://raw.githubusercontent.com/kodmial/nanodictate/main/scripts/install-macports.sh"

# 1) MacPorts обязателен -------------------------------------------------------
if ! command -v port >/dev/null 2>&1; then
  echo "==> MacPorts не найден. Установи его с https://www.macports.org/install.php и запусти скрипт заново." >&2
  exit 1
fi

# 2) Перевызов под sudo --------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
  if [ -f "$0" ]; then
    # Обычный файл на диске — просто перевызываем себя под sudo
    # (обычный запрос пароля; sudo -n не используем).
    # sudo очищает env — NANODICTATE_* пробрасываем явно, иначе канон-дерево
    # и флаг NANODICTATE_SKIP_INSTALL теряются.
    exec sudo env NANODICTATE_TREE="${NANODICTATE_TREE:-}" \
      NANODICTATE_SKIP_INSTALL="${NANODICTATE_SKIP_INSTALL:-}" \
      bash "$0" "$@"
  else
    # Запуск через `bash <(curl ...)`: $0 — уже вычитанный pipe (/dev/fd/N,
    # читается 0 байт), а sudo закрывает все файловые дескрипторы >= 3, так
    # что `sudo bash "$0"` не сработает. Скачиваем установщик заново во
    # временный файл и запускаем его под sudo.
    STAGE="$(mktemp /tmp/install-macports.XXXXXX.sh)"
    # trap стоит до exec, но exec подменяет образ процесса и НЕ переносит
    # trap в новый процесс: этот trap живёт, только если curl-ветка выйдет
    # через exit (не exec). Для sudo-процесса путь передаётся через
    # NANODICTATE_STAGE, и root-процесс ставит свой trap ниже, после
    # sudo-блока, внутри скрипта.
    trap 'rm -f "$STAGE"' EXIT
    curl -fsSL "$SCRIPT_URL" -o "$STAGE" || {
      echo "==> не удалось загрузить установщик: $SCRIPT_URL" >&2
      exit 1
    }
    exec sudo env NANODICTATE_TREE="${NANODICTATE_TREE:-}" \
      NANODICTATE_SKIP_INSTALL="${NANODICTATE_SKIP_INSTALL:-}" \
      NANODICTATE_STAGE="$STAGE" bash "$STAGE" "$@"
  fi
fi

# Временный установщик, скачанный curl-веткой выше: root-процесс удаляет его
# на выходе (rm -f idempotентен — повторный запуск безопасен). Trap ставится
# именно здесь, ДО всех exec, и выполняется при выходе sudo-процесса, потому
# что команда rm живёт ВНУТРИ скрипта, а путь приходит через env.
if [ -n "${NANODICTATE_STAGE:-}" ]; then
  trap 'rm -f "$NANODICTATE_STAGE"' EXIT
fi

# 3) Пользователь --------------------------------------------------------------
U="${SUDO_USER:-$USER}"        # тот, кто запустил установку (не root)
case "$U" in
  ''|*[!A-Za-z0-9._-]*) echo "==> недопустимое имя пользователя: $U" >&2; exit 1 ;;
esac
H="$(dscl . -read "/Users/$U" NFSHomeDirectory 2>/dev/null | awk -F': ' '{print $2}')"
if [ -z "$H" ]; then
  # dscl не сработал — фолбэк на eval (безопасен: $U уже отвалидирован выше)
  H="$(eval echo "~${U}")"
fi

# 4) Канон-дерево --------------------------------------------------------------
P="${NANODICTATE_TREE:-/Users/Shared/macports-nanodictate}"
S="file://$P"
PORT_BIN="$(command -v port)"                                   # /opt/local/bin/port
PREFIX_DIR="$(dirname "$(dirname "$PORT_BIN")")"                # /opt/local
PINDEX="$PREFIX_DIR/bin/portindex"

# Доверенная закреплённая ревизия kodmial/macports-nanodictate — единственный
# источник истины для дерева: наличие .git аутентичность НЕ доказывает, чекаут
# обязан сидеть ровно на этой ревизии. Обновляется шагом «Sync MacPorts port
# tree» в .github/workflows/release.yml — на только что синкнутый HEAD дерева
# (сгенерированный релизный Portfile), сохраняя exact-revision чекаут.
PIN_REV="4c4ced254593e3865d9f6a8f99ab6c7a3c59f807"

if [ -d "$P/.git" ]; then
  echo "==> канон-дерево уже есть: $P"
else
  echo "==> клонирую канон-дерево: $P"
  # core.hooksPath=/dev/null: git-команды этого скрипта работают от root на
  # дереве, которое мог подготовить локальный аккаунт, — хуки из .git/hooks
  # не выполняем (CWE-829).
  git -c core.hooksPath=/dev/null clone https://github.com/kodmial/macports-nanodictate "$P"
fi

# Аутентичность (CWE-829): локальный аккаунт может создать $P до запуска
# админом. origin обязан указывать на канон kodmial/macports-nanodictate
# (https / git@ / ssh:// форма, опциональный .git) — свой форк или подменённый
# remote означает чужое дерево: portindex под root его не обработает.
ORIGIN_URL="$(git -C "$P" remote get-url origin 2>/dev/null || true)"
CANON_URL="$(printf '%s' "$ORIGIN_URL" \
  | sed -E 's#^git@github\.com:#https://github.com/#' \
  | sed -E 's#^ssh://git@github\.com/#https://github.com/#' \
  | sed -E 's#\.git$##; s#/$##')"
if [ "$CANON_URL" != "https://github.com/kodmial/macports-nanodictate" ]; then
  echo "==> ОШИБКА: origin канон-дерева не указывает на kodmial/macports-nanodictate (факт: ${ORIGIN_URL:-<нет remote>})" >&2
  exit 1
fi

echo "==> проверяю канон-дерево на закреплённую ревизию $PIN_REV ..."
# Чистота ДО git-мутаций от root: checkout/reset не удаляют untracked-файлы,
# а любой модифицированный/untracked Portfile portindex (от root) обработал бы
# как канон. Требуем пустой porcelain — ошибка при любой грязи.
if [ -n "$(git -C "$P" status --porcelain)" ]; then
  echo "==> ОШИБКА: канон-дерево не чистое (есть модифицированные/untracked файлы)." >&2
  echo "    Их portindex обработал бы от root — прерываю. Восстанови $P (или удали) и запусти заново." >&2
  exit 1
fi
HEAD_REV="$(git -C "$P" rev-parse HEAD)"
if [ "$HEAD_REV" != "$PIN_REV" ]; then
  echo "==> HEAD ($HEAD_REV) != $PIN_REV — подтягиваю и переставляю (hard reset)"
  git -C "$P" -c core.hooksPath=/dev/null fetch origin
  git -C "$P" -c core.hooksPath=/dev/null reset --hard "$PIN_REV"
  HEAD_REV="$(git -C "$P" rev-parse HEAD)"
fi
if [ "$HEAD_REV" != "$PIN_REV" ]; then
  echo "==> ОШИБКА: канон-дерево не удалось привести к закреплённой ревизии $PIN_REV (HEAD = $HEAD_REV)" >&2
  exit 1
fi
echo "==> канон-дерево на закреплённой ревизии $PIN_REV"

if [ "$(stat -f %u "$P")" = 0 ]; then
  echo "==> владелец дерева root — ок"
else
  echo "==> отдаю дерево root:admin (для git pull от имени root)"
  chown -R root:admin "$P"
fi

# Финальный инвариант перед обработкой дерева от root: после chown дерево
# заморожено (локальный аккаунт уже не может его менять), HEAD == PIN_REV
# проверен выше — остаётся чистота. portindex увидит ровно канон.
if [ -n "$(git -C "$P" status --porcelain)" ]; then
  echo "==> ОШИБКА: канон-дерево не чистое — portindex от root НЕ запускаю (модифицированные/untracked файлы в $P)." >&2
  exit 1
fi

# 5) Эффективный sources.conf --------------------------------------------------
C="$PREFIX_DIR/etc/macports/sources.conf"
MC="$H/.macports/macports.conf"
USER_CONF=0
if [ -f "$MC" ] && grep -Eq '^[[:space:]]*sources_conf([[:space:]]|$)' "$MC"; then
  SC_VAL="$(grep -E '^[[:space:]]*sources_conf([[:space:]]|$)' "$MC" | head -n 1 | awk '{print $2}')"
  if [ -n "$SC_VAL" ]; then
    case "$SC_VAL" in
      /*) C="$SC_VAL" ;;                              # абсолютный путь
      '~/'*) C="$H/${SC_VAL#'~/'}" ;;                # ~/... — относительно $H
      *) C="$H/$SC_VAL" ;;                            # относительный — тоже $H
    esac
    # Пользовательский файл — владельца вернём после правки. Но если
    # sources_conf указывает на системный дефолт (копию дефолтного
    # macports.conf) — правится системный файл, chown не нужен.
    if [ "$C" != "$PREFIX_DIR/etc/macports/sources.conf" ]; then
      USER_CONF=1
    fi
  fi
fi
echo "==> эффективный sources.conf: $C"

if grep -qxF "$S" "$C" 2>/dev/null; then
  echo "==> источник уже прописан: $S"
else
  if grep -qF '[default]' "$C" 2>/dev/null; then
    # BSD sed: вставить источник ПЕРЕД строкой [default] — первое совпадение
    # побеждает, наше дерево затеняет rsync-источник.
    echo "==> вставляю источник перед [default] в $C"
    sed -i "" "/\[default\]/i\\
$S
" "$C"
  else
    echo "==> [default] не найден — дописываю источник в конец $C"
    echo "$S" >> "$C"
  fi
fi

if [ "$USER_CONF" = "1" ]; then
  # пользовательский файл правили под root — вернём владельца
  chown "$U" "$C"
fi

# 6) Индекс канон-дерева -------------------------------------------------------
echo "==> обновляю индекс канон-дерева (portindex) ..."
cd "$P"
"$PINDEX"

# 7) Установка порта -----------------------------------------------------------
if [ "${NANODICTATE_SKIP_INSTALL:-0}" = "1" ]; then
  echo "==> NANODICTATE_SKIP_INSTALL=1 — пропускаю port install"
else
  echo "==> устанавливаю порт nanodictate ..."
  port install nanodictate
  echo "==> порт nanodictate установлен"
  if "$PREFIX_DIR/bin/nanodictate" --version >/dev/null 2>&1; then
    echo "==> бинарь отвечает: $("$PREFIX_DIR/bin/nanodictate" --version 2>&1)"
  else
    echo "==> ВНИМАНИЕ: $PREFIX_DIR/bin/nanodictate не отвечает на --version" >&2
  fi
  if port installed | grep nanodictate; then
    echo "==> порт nanodictate виден в port installed"
  fi
  # Статус launchd — через GUI-домен запускающего пользователя $U и канонический
  # label: `launchctl list` от root смотрит домен root и LaunchAgent в gui/<uid>
  # не видит (ложный «не запущен»).
  U="${U:-$USER}"
  if launchctl print "gui/$(id -u "$U")/com.nanodictate.agent" >/dev/null 2>&1; then
    echo "==> служба запущена (com.nanodictate.agent в launchd)"
  else
    echo "==> служба зарегистрирована и стартует при следующем входе (RunAtLoad)"
  fi
fi

echo "==> Готово. Нажми Alt+Alt — откроются настройки Доступности"