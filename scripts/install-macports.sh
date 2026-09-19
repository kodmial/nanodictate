#!/bin/bash
#
# install-macports.sh — one-shot NanoDictate installer via MacPorts (binary tarball).
#
#   curl -fsSL https://raw.githubusercontent.com/kodmial/nanodictate/main/scripts/install-macports.sh | bash
#
# Installs the prebuilt v0.0.1 binary tarball (from the GitHub Release) as a
# MacPorts port — no Xcode / Swift toolchain needed on the user's machine.
#
# Steps:
#   1. requires MacPorts (`port` on PATH — get it from https://www.macports.org)
#   2. fetches the generated packaging/macports/Portfile from the repo main
#   3. runs `portindex` in a local ports tree (the Portfile is parsed here too)
#   4. adds the local tree to /opt/local/etc/macports/sources.conf BEFORE the
#      [default] source (file:// sources must shadow the remote ones)
#   5. `sudo port install nanodictate` — with sudo, SUDO_USER is set, so the
#      port's post-destroot writes the canonical LaunchAgent plist
#      (~/Library/LaunchAgents/com.nanodictate.agent.plist) and bootstraps it
#      into launchd — Alt+Alt works right after install.
#   6. verifies the install and prints OK.
#
# The local ports tree lives in /Users/Shared (not $HOME): the MacPorts fetch
# phase drops privileges to the `macports` user, which cannot traverse
# /Users/<user> (mode 750) — /Users/Shared is world-traversable. The standard
# tree layout is <tree>/<category>/<portname>/Portfile, so the Portfile lands
# at ${TREE}/audio/nanodictate/Portfile.
#
# Set MACPORTS_TREE=/some/other/path to use a custom tree location.

set -euo pipefail

TREE="${MACPORTS_TREE:=/Users/Shared/MacPorts/ports}"
PORT_DIR="${TREE}/audio/nanodictate"
SOURCES_CONF="/opt/local/etc/macports/sources.conf"
PORTFILE_URL="https://raw.githubusercontent.com/kodmial/nanodictate/main/packaging/macports/Portfile"
PREFIX="${prefix:-/opt/local}"

# 1) MacPorts required ---------------------------------------------------------
if ! command -v port >/dev/null 2>&1; then
  echo "MacPorts не установлен — поставь с macports.org (https://www.macports.org/install.php)" >&2
  exit 1
fi

# 2) Fetch the generated Portfile into the local ports tree --------------------
mkdir -p "${PORT_DIR}"
curl -fsSL -o "${PORT_DIR}/Portfile" "${PORTFILE_URL}"
echo "port: Portfile -> ${PORT_DIR}/Portfile"

# 3) Index the local tree (this also validates the Portfile syntax) ------------
cd "${TREE}"
portindex -e

# 4) Register the local source BEFORE the [default] rsync source ---------------
LOCAL_SOURCE="file://${TREE}"
if ! grep -qF "${LOCAL_SOURCE}" "${SOURCES_CONF}" 2>/dev/null; then
  # BSD sed: insert before the line that ends with literal [default].
  sudo sed -i '' "/\[default\]\$/i\\
${LOCAL_SOURCE}
" "${SOURCES_CONF}"
  # Fallback: no [default] line in the file — append the source at the end.
  if ! grep -qF "${LOCAL_SOURCE}" "${SOURCES_CONF}" 2>/dev/null; then
    echo "${LOCAL_SOURCE}" | sudo tee -a "${SOURCES_CONF}" >/dev/null
  fi
  echo "port: added ${LOCAL_SOURCE} to ${SOURCES_CONF}"
fi

# 5) Install. sudo sets SUDO_USER so post-destroot registers the LaunchAgent
#    (the same canonical com.nanodictate.agent, identical to `nanodictate start`)
sudo port install nanodictate

# 6) Verify ---------------------------------------------------------------------
port installed | grep nanodictate
"${PREFIX}/bin/nanodictate" --version
if launchctl list 2>/dev/null | grep -q nanodictate; then
  echo "service: com.nanodictate.agent loaded in launchd"
else
  echo "service: not loaded yet — it starts at login (RunAtLoad), or run 'nanodictate start'"
fi
echo "OK: nanodictate installed"