#!/usr/bin/env bash
# Build AltDictation: swift build (system Swift or a custom toolchain),
# re-sign both binaries, and symlink dictatorctl into /usr/local/bin so it
# works as a plain command without a path.
#
# Environment (all optional):
#   SWIFT_TOOLCHAIN=/path/to/toolchain   unset -> use `swift` from PATH
#   SIGN_IDENTITY="Name"                 unset -> first keychain identity; if none -> ad-hoc
set -euo pipefail

cd "$(dirname "$0")"

# --- Swift toolchain ------------------------------------------------------
if [[ -n "${SWIFT_TOOLCHAIN:-}" ]]; then
    if [[ ! -x "$SWIFT_TOOLCHAIN/usr/bin/swift" ]]; then
        echo "ERROR: SWIFT_TOOLCHAIN is set, but no swift binary at $SWIFT_TOOLCHAIN/usr/bin/swift" >&2
        exit 1
    fi
    # Manifest parsing requires the toolchain's swiftc and SwiftPM libs.
    export SWIFT_EXEC_MANIFEST="$SWIFT_TOOLCHAIN/usr/bin/swiftc"
    export SWIFTPM_CUSTOM_LIBS_DIR="$SWIFT_TOOLCHAIN/usr/lib/swift/pm"
    SWIFT="$SWIFT_TOOLCHAIN/usr/bin/swift"
    echo "==> swift toolchain: $SWIFT_TOOLCHAIN"
else
    if ! command -v swift >/dev/null 2>&1; then
        echo "ERROR: 'swift' not found in PATH. Install Xcode Command Line Tools, or set SWIFT_TOOLCHAIN." >&2
        exit 1
    fi
    SWIFT="swift"
    echo "==> swift: $(command -v swift)"
fi

echo "==> swift build"
"$SWIFT" build

# --- Code signing ----------------------------------------------------------
# Signing identity: explicit SIGN_IDENTITY wins; otherwise the first valid
# (keychain, non-ad-hoc) identity from `security find-identity`.
IDENTITY=""
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    IDENTITY="$SIGN_IDENTITY"
else
    IDENTITY="$(security find-identity -p codesigning -v 2>/dev/null | awk -F'"' '/\)/ && NF >= 2 { print $2; exit }' || true)"
fi

if [[ -z "$IDENTITY" ]]; then
    echo "WARNING: no codesigning identity found in the keychain — signing ad-hoc." >&2
    echo "         macOS privacy (TCC) grants are keyed to the code signature; with ad-hoc" >&2
    echo "         signing, every rebuild invalidates Microphone/Accessibility grants and" >&2
    echo "         you must grant the permissions again." >&2
    echo "         To keep grants stable across rebuilds, create a 'Sign to Run Locally'" >&2
    echo "         certificate and rebuild with it:" >&2
    echo "           Keychain Access -> Certificate Assistant -> Create a Certificate..." >&2
    echo "           Name: e.g. \"Local Code Signing\"" >&2
    echo "           Identity Type: Self-Signed Root; Certificate Type: Code Signing" >&2
    echo "           SIGN_IDENTITY=\"Local Code Signing\" ./build.sh" >&2
    IDENTITY="-"
fi

echo "==> codesign DictatorAgent"
codesign --force --sign "$IDENTITY" --identifier com.dictation.agent .build/debug/DictatorAgent

echo "==> codesign dictatorctl"
codesign --force --sign "$IDENTITY" --identifier com.dictation.dictatorctl .build/debug/dictatorctl

# Symlink so `dictatorctl` is callable as a plain command.
# Because /usr/local/bin/dictatorctl is a symlink (not a copy), every rebuild
# makes the fresh binary available immediately.
BIN_PATH="$(pwd)/.build/debug/dictatorctl"
if [ -d /usr/local/bin ] && [ -w /usr/local/bin ]; then
    echo "==> ln -sf $BIN_PATH /usr/local/bin/dictatorctl"
    ln -sf "$BIN_PATH" /usr/local/bin/dictatorctl
else
    echo "WARNING: /usr/local/bin is not writable — symlink NOT created." >&2
    echo "         Options: sudo chown $(whoami) /usr/local/bin," >&2
    echo "         or use ~/bin with 'export PATH=\"\$HOME/bin:\$PATH\"' in ~/.zshrc." >&2
fi

echo "==> done: $(which dictatorctl 2>/dev/null || echo 'dictatorctl not found in PATH')"