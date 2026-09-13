#!/usr/bin/env bash
# Сборка AltDictation: swift build через локальный toolchain,
# переподпись обоих бинарей и обновление симлинка dictatorctl в /usr/local/bin,
# чтобы `dictatorctl` работал как обычная команда без пути.
set -euo pipefail

cd "$(dirname "$0")"

export SWIFT_EXEC_MANIFEST="$HOME/.swift-toolchain/usr/bin/swiftc"
export SWIFTPM_CUSTOM_LIBS_DIR="$HOME/.swift-toolchain/usr/lib/swift/pm"
SWIFT="$HOME/.swift-toolchain/usr/bin/swift"

echo "==> swift build"
"$SWIFT" build

echo "==> codesign DictatorAgent"
codesign --force --sign "Dictation Code Signing" --identifier com.dictation.agent .build/debug/DictatorAgent

echo "==> codesign dictatorctl"
codesign --force --sign "Dictation Code Signing" --identifier com.dictation.dictatorctl .build/debug/dictatorctl

# Симлинк, чтобы `dictatorctl` вызывался как обычная команда.
# Из-за symlink (а не копии) после каждой пересборки в /usr/local/bin
# оказывается свежий бинарь.
BIN_PATH="$(pwd)/.build/debug/dictatorctl"
if [ -d /usr/local/bin ] && [ -w /usr/local/bin ]; then
    echo "==> ln -sf $BIN_PATH /usr/local/bin/dictatorctl"
    ln -sf "$BIN_PATH" /usr/local/bin/dictatorctl
else
    echo "ВНИМАНИЕ: /usr/local/bin недоступен для записи — симлинк НЕ создан." >&2
    echo "        Варианты: sudo chown $(whoami) /usr/local/bin," >&2
    echo "        либо ~/bin + 'export PATH=\"\$HOME/bin:\$PATH\"' в ~/.zshrc." >&2
fi

echo "==> готово: $(which dictatorctl 2>/dev/null || echo 'dictatorctl не найден в PATH')"