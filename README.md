# NanoDictate

Live voice dictation into any macOS app (12+). Double-tap **Alt** to start and
stop: speak, and the recognized text is typed into the focused app. No clicks,
no window switching. Two pieces:

- `NanoDictateAgent` — background agent (LaunchAgent), does the recording and
  text insertion
- `nanodictate` — control CLI

STT runs on OpenAI, Groq, Cloudflare Workers AI, or any OpenAI-compatible
endpoint. Default provider `airubiz` needs no key. Release binaries are signed
with a stable identity, so Microphone/Accessibility grants survive upgrades.

## Install

### Homebrew

```sh
brew tap kodmial/homebrew-nanodictate
brew install nanodictate
brew services start nanodictate   # start the background dictation agent (outside the sandbox)
```

The first two commands install the prebuilt binary (nothing is compiled — no
Xcode needed). The explicitly named tap is the repository that serves the
formula — `brew install nanodictate` with no tap line auto-taps it anyway.
The last command registers the background agent and starts it now and at
every login: the formula's sandboxed `post_install` (Homebrew ≥ 7) cannot
write `~/Library/LaunchAgents`, so the explicit start is mandatory; on older
Homebrew it is an idempotent no-op. `brew services stop nanodictate` stops it.

Prefer an app bundle?

```sh
brew install --cask nanodictate
```

Installs **NanoDictate.app** — the same two binaries in a `.app`, background
agent only (no Dock icon). Same single daemon as the formula: one
`~/Library/LaunchAgents/com.nanodictate.agent.plist`, register it once with
`nanodictate start`.

### MacPorts

The port is not in the official MacPorts tree yet, so a bare
`sudo port install nanodictate` does not work on a clean machine. First install
is **two idempotent commands** — the first registers this repo as a git port
source, the second installs the same prebuilt binary and keeps itself updated:

```bash
sudo bash -c '
set -e
P=/Users/Shared/macports-nanodictate
C=/opt/local/etc/macports/sources.conf
U="${SUDO_USER:-$USER}"
H="$(dscl . -read "/Users/$U" NFSHomeDirectory 2>/dev/null | awk -F'"'"': '"'"' '"'"'{print $2}'"'"')"
[ -n "$H" ] || H="$(eval echo "~${U}")"
MC="$H/.macports/macports.conf"
USER_CONF=0
if [ -f "$MC" ] && grep -Eq '"'"'^[[:space:]]*sources_conf([[:space:]]|$)'"'"' "$MC"; then
  SC_VAL="$(grep -E '"'"'^[[:space:]]*sources_conf([[:space:]]|$)'"'"' "$MC" | head -n 1 | awk '"'"'{print $2}'"'"')"
  if [ -n "$SC_VAL" ]; then
    case "$SC_VAL" in
      /*) C="$SC_VAL" ;;
      '"'"'~/'"'"'*) C="$H/${SC_VAL#'"'"'~/"'"'"'}" ;;
      *) C="$H/$SC_VAL" ;;
    esac
    [ "$C" = "/opt/local/etc/macports/sources.conf" ] || USER_CONF=1
  fi
fi
S="file://$P"
[ -d "$P/.git" ] || git clone https://github.com/kodmial/macports-nanodictate "$P"
[ "$(stat -f %u "$P")" = 0 ] || chown -R root:admin "$P"
grep -qxF "$S" "$C" || { grep -qF "[default]" "$C" && sed -i "" "/\[default\]/i\\
$S
" "$C" || echo "$S" >> "$C"; }
if [ "$USER_CONF" = 1 ]; then chown "$U" "$C"; fi
'

sudo port selfupdate && sudo port install nanodictate
```

The first command clones the canon tree `kodmial/macports-nanodictate` into
`/Users/Shared/macports-nanodictate` and inserts its `file://` source into
`sources.conf` (before `[default]` — first match wins); the second
installs the port. The port's `post-activate` registers the
global LaunchAgent and bootstraps it — **the service is alive right after
install**, no `nanodictate start` needed, and it comes back after every reboot
(RunAtLoad + KeepAlive).

Same prebuilt tarball as Homebrew, nothing compiled. `/Users/Shared` survives
a MacPorts reinstall, so the same first command is also the recovery after one.
Every future release is picked up by:

```sh
sudo port selfupdate && sudo port upgrade nanodictate
```

### After install

Only manual step: grant **Microphone** and **Accessibility** to
`NanoDictateAgent` once — System Settings → Privacy & Security (add **Input
Monitoring** if the hotkey does not fire). Then double-**Alt** and speak. No
config, no keys: `~/.config/nanodictate/config.toml` is created from the
bundled `config.example.toml` on first launch.

## Configuration

Config lives at `~/.config/nanodictate/config.toml` (chmod 600, atomic
writes). `nanodictate config init` recreates it from the bundled example
`config.example.toml` — the single source of defaults.

Top-level options: `active_provider` (STT backend, default `airubiz`),
`language` (STT hint; empty = auto-detect), `sounds_enabled`, `timeout_seconds`,
`log_level`. Per-provider sections take `api_key` (or `api_key_file`),
`base_url` and `model` — any OpenAI-compatible endpoint works by setting
`base_url` + `model` in its section. `NANODICTATE_API_KEY` overrides the file
for the active provider only and is never written to disk. Full list of
sections and options — see [config.example.toml](config.example.toml).

## Usage

```sh
nanodictate start | stop | status
nanodictate config init           # recreate config from the bundled example
nanodictate config set-key <id>   # set an API key interactively
nanodictate provider use <id>     # switch active provider
nanodictate transcribe FILE       # one-shot file transcription
nanodictate logs                  # last 50 log lines
```

Double-**Alt** starts dictation, double-**Alt** stops (**Esc** cancels; a
double-**Alt** right after an insertion undoes it). Run `nanodictate` with no
arguments for the interactive TUI (status, provider list, log viewer,
EN/RU language toggle).

## Development

```sh
swift build -c debug              # or -c release
swift run NanoDictateCoreTests    # executable target — `swift test` does not run it
swift run nanodictate --help
```

A Node.js MCP server automates build + sign + restart of the agent with a
stable signature (`mcp/nanodictate-deploy-mcp-server/`, see its
[README](mcp/nanodictate-deploy-mcp-server/README.md)). Build locally with a
raw `swift build` only for testing: macOS TCC grants (Microphone,
Accessibility) are keyed to the binary's signature, and an ad-hoc-signed
rebuild changes it, so re-grant the permissions once after such a build.

## Uninstall

**Homebrew** — `nanodictate stop` then `brew uninstall nanodictate` (the plist
and config stay behind — remove them by hand if you want them gone).
**Cask** — `brew uninstall --cask nanodictate` removes the app only.
**MacPorts** — `sudo port uninstall nanodictate` boots out the agent and
removes the global plist in one command; only your config and logs stay behind.

## License

[MIT](LICENSE) — Copyright (c) 2026 NanoDictate contributors.