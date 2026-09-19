# NanoDictate

On-screen dictation for macOS, triggered by a double-tap of the **Alt** key.
Press **Alt** twice, speak, press **Alt** twice again — the recognized text is
typed into whatever app is currently focused.

Built as a Swift Package Manager package (`swift-tools-version:5.7`, macOS 12+).

## Components

- **NanoDictateCore** — shared library with the core dictation logic (recording,
  STT, overlay, text insertion, provider adapters, silence auto-stop, batch
  transcription).
- **NanoDictateAgent** — background LaunchAgent daemon that listens for the
  trigger, shows the overlay, and performs the dictation work.
- **nanodictate** — command-line control utility and interactive TUI status
  menu (start/stop the agent, inspect config, pick providers, transcribe
  files, show logs).

## Features

- Double-**Alt** start/stop dictation; **Esc** cancels.
- Interactive TUI status menu (`nanodictate`) with agent state, provider list,
  log viewer, and language toggle as the first menu item.
- Bilingual UI (English and Russian); set `ui_language = "en"` or `"ru"` in
  config (default: `"en"`).
- Overlay panel with live input level, recording/progress/status phases.
- Text insertion via CGEvent keyboard events (default) or clipboard + Cmd+V
  (`insert_method = "clipboard"`, restores previous clipboard).
- Undo window: a double-**Alt** shortly after an insertion removes it.
- Silence auto-stop (~3 s of quiet) with configurable duration and RMS
  threshold; environment variables
  `NANODICTATE_AUTOSTOP_DISABLED`, `NANODICTATE_AUTOSTOP_DURATION`,
  `NANODICTATE_AUTOSTOP_RMS`.
- Batch file transcription with chunked segments, parallel workers, pause
  cutting, checkpoint/resume, and a progress bar.
- Multi-provider STT via adapters implementing the OpenAI-compatible
  `/audio/transcriptions` protocol:
  - **OpenAI** (`openai`)
  - **Groq** (`groq`)
  - **GigaAM** (`gigaam`, default batch provider)
  - **Local** (`local`, local whisper/llama.cpp/faster-whisper server)
  - **Cloudflare Workers AI** (`cloudflare`, raw WAV + Bearer token, full URL
    with `account_id` in path)
  - **Cookie Relay** (`cookie-relay`, JS-challenge relay with computed
    `__test` cookie)
  - Any OpenAI-compatible endpoint via the generic `openai-compatible` adapter
- Proxy transports (see [Proxy Transports](#proxy-transports)).
- Optional review gate (`review_before_insert`) — confirm the text in the
  terminal before it is typed.
- Auto-failover between providers (`auto_failover`) and manual retry
  (`nanodictate retry <provider>`).
- TOML configuration at `~/.config/nanodictate/config.toml`.

## Installation

Choose one of the three distribution paths. Homebrew and MacPorts are
planned but not live yet (TODOs below); ready-to-run binaries for the latest
release are always available from **GitHub Releases**.

> **No Developer ID / no notarization (deliberate).** There is no paid Apple
> Developer account behind this project, so release binaries are unsigned
> (ad-hoc) and macOS may block *browser* downloads via Gatekeeper. See
> [docs/packaging/homebrew.md](docs/packaging/homebrew.md) and
> [docs/packaging/macports.md](docs/packaging/macports.md) for the details
> and the `xattr` workaround below.

### Homebrew (coming soon)

The formula is a **binary formula**: `brew` downloads the prebuilt tarball
from GitHub Releases and installs it as-is — no Xcode / Swift toolchain
needed. TODO: the tap repository is not created yet, so the command below is
pending.

```sh
brew install kodmial/nanodictate-homebrew/nanodictate
```

Requires **macOS 12+** only. Until the tap exists you can install the
generated formula directly:
`brew install /path/to/nanodictate/packaging/homebrew/nanodictate.rb`
(also a binary download — nothing is compiled).

### MacPorts (coming soon)

The port is pending a PR to `macports-ports` (TODO: not accepted yet). It
also builds from source:

```sh
sudo port install nanodictate
```

Requires **Xcode 14.3+** — the port sets `use_xcode yes` (there is no Swift
port in MacPorts). Expect a long first build: SwiftPM compiles the whole
package from source.

### GitHub Releases (current)

Prebuilt tarballs for both architectures are attached to every release —
`nanodictate-0.1.0-macos-$(uname -m).tar.gz` resolves to
`nanodictate-0.1.0-macos-arm64.tar.gz` on Apple Silicon and to
`nanodictate-0.1.0-macos-x86_64.tar.gz` on Intel:

```sh
curl -L -O https://github.com/kodmial/nanodictate/releases/download/v0.1.0/nanodictate-0.1.0-macos-$(uname -m).tar.gz
curl -L -O https://github.com/kodmial/nanodictate/releases/download/v0.1.0/SHA256SUMS.txt
shasum -a 256 -c SHA256SUMS.txt        # optional: verifies the downloaded tarball
```

Extract into a directory and keep everything together — the CLI resolves the
LaunchAgent plist template at `Resources/nanodictate-agent.plist.template`
**next to the binary**:

```sh
mkdir -p ~/.local/bin
tar xzf nanodictate-0.1.0-macos-$(uname -m).tar.gz
cp NanoDictateAgent nanodictate ~/.local/bin/          # or /usr/local/bin with sudo
cp -R Resources ~/.local/bin/                          # keep the plist template findable
export PATH="$HOME/.local/bin:$PATH"
```

Then create the config, grant permissions and start the agent:

```sh
mkdir -p ~/.config/nanodictate
cp config.example.toml ~/.config/nanodictate/config.toml   # then set STT providers / API keys
nanodictate config init                                     # alternative: writes a default config
nanodictate start                                           # bootstraps ~/Library/LaunchAgents/com.nanodictate.agent.plist
```

**Permissions (manual, required).** In **System Settings > Privacy &
Security** add the `NanoDictateAgent` binary to **Microphone** and
**Accessibility** (and **Input Monitoring** if the hotkey does not fire).
macOS prompts on first use; grants are per-binary.

**Browser downloads** (unlike `curl` and `brew`) get a `com.apple.quarantine`
attribute, and Gatekeeper then refuses to run the unsigned ad-hoc binaries.
Clear it once:

```sh
xattr -dr com.apple.quarantine ~/.local/bin/NanoDictateAgent ~/.local/bin/nanodictate
```

Requires **macOS 12+**. Xcode Command Line Tools are needed only for the
MacPorts build-from-source path; the Homebrew formula and the GitHub Releases
binaries run as-is. Once installed, see [Install & Run](#install--run) for the
LaunchAgent, CLI and configuration details.

## Build & Test

Requirements: macOS 12+ and a Swift **5.7+** toolchain (below); Node.js ≥ 22
is needed only for the deploy MCP server.

### Build requirements

The package uses `swift-tools-version:5.7`, so it builds with any **Swift 5.7+**
toolchain — Xcode 14+ or the Command Line Tools with SwiftPM. Use the standard
SwiftPM commands:

```sh
swift build -c debug      # or -c release
swift run nanodictate --help
```

`mcp/nanodictate-deploy-mcp-server/start.sh` (deploy MCP server) runs the same
`swift build` internally; it auto-detects the toolchain via `xcrun --find
swift` unless the `SWIFT_TOOLCHAIN` environment variable points at a specific
toolchain.

### Tests

The tests are packaged as a standalone executable target
(`NanoDictateCoreTests`) rather than XCTest test targets, so they are run with
`swift run` instead of `swift test` (the package declares no test targets for
`swift test` to discover). The runner executes every `test*` method, prints a
summary, and exits non-zero if any test fails. The current suite runs
**771 tests**. The same commands are used by the CI workflow
(`.github/workflows/ci.yml`).

```sh
swift run NanoDictateCoreTests
```

### Code signing — `NanoDictate Code Signing`

macOS TCC grants (Microphone, Accessibility) are keyed to the binary's cdhash.
Ad-hoc signing on every rebuild produces a new cdhash and resets all grants —
the agent stops reacting to Alt+Alt until permissions are re-granted. Builds
must use the fixed identity **NanoDictate Code Signing** (see
[Code Signing](#code-signing) below). The only supported path is the MCP
deploy server (`dictation_sign` / `dictation_deploy`) — it runs
`codesign --force --sign "NanoDictate Code Signing" --entitlements
Resources/*.entitlements --options runtime --identifier <bundle-id>` and then
`codesign --verify --strict`. It has no ad-hoc fallback: if the identity is
missing, it fails with instructions. Raw `swift build` + `codesign` / manual
`security` calls from scripts or subagents break TCC — do not use them.

Create the identity once in **Keychain Access > Certificate Assistant >
Create a Certificate...** — Name `NanoDictate Code Signing`, Identity Type
Self-Signed Root, Certificate Type Code Signing — then verify with
`security find-identity -p codesigning -v`.

### Permissions — Микрофон + Универсальный доступ

After the first signed build, grant two permissions in **System Settings >
Privacy & Security**:

- **Микрофон (Microphone)** — audio capture (`com.apple.security.device.audio-input`).
- **Универсальный доступ (Accessibility)** — global Alt+Alt hotkey and text
  insertion via `CGEvent` (TCC grant, not an entitlement).

Add the *signed* binary (`.build/debug/NanoDictateAgent`) to each list. The
path is bound to the cdhash of that exact signed binary — after an ad-hoc
rebuild the checkbox resets and the hotkey goes dead; re-sign with the stable
identity and re-grant once. **Input Monitoring** may also be required on some
macOS versions if the hotkey does not fire — add the same binary there if
needed. See [Code Signing](#code-signing) and
[Permissions](#permissions) for details.

### MCP server — Node.js ≥ 22

The deploy MCP server (`mcp/nanodictate-deploy-mcp-server/`, symlink
`mcp/dictation-deploy-mcp-server` → same directory) automates build + sign +
restart with a stable signature. Requires **Node.js ≥ 22** (`engines` in
`package.json`) and the Swift toolchain above (its tools shell out to
`swift build` / `codesign`).

```sh
cd mcp/nanodictate-deploy-mcp-server
npm install            # or: npm ci (package-lock.json is committed)
npm run build          # tsc → dist/
npm test               # npm run build && node --test
npm start              # node dist/index.js (stdio MCP transport)
```

`dist/` and `node_modules/` are gitignored and **absent on a fresh clone**
— running `dist/index.js` directly would fail with `ENOENT`. `start.sh`
is the entry point for MCP clients: when `dist/index.js` is missing it
installs dependencies (`npm ci` → fallback `npm install`) and builds (`tsc`),
then `exec`s the compiled server (build log → `.start-build.log`, errors →
stderr, never stdout — that would corrupt MCP JSON-RPC). Register it in
`~/.claude.json` as `bash $PROJECT_ROOT/mcp/nanodictate-deploy-mcp-server/start.sh`
(not in project `settings.json`).

Other scripts: `npm run typecheck` (`tsc --noEmit`), `npm run test:coverage`
(`npm run build && node --test --experimental-test-coverage`), `npm run clean`
(`rm -rf dist`). See [Deploy (MCP Server)](#deploy-mcp-server) for the
exposed tools.

## Install & Run

### LaunchAgent (NanoDictateAgent)

```sh
# Install and start the LaunchAgent
nanodictate start

# Check status
nanodictate status

# Stop the agent
nanodictate stop
```

The agent installs a plist template (`Resources/nanodictate-agent.plist.template`)
as `~/Library/LaunchAgents/com.nanodictate.agent.plist` and bootstraps it into
`launchd`. The `start` command is idempotent.

### CLI & TUI (nanodictate)

```sh
nanodictate start | stop | status
nanodictate config init [--force]         # create default config.toml
nanodictate config path                   # show config path
nanodictate config set-key <provider>     # set API key interactively
nanodictate provider list                 # list configured providers
nanodictate provider use <name>           # set active provider
nanodictate routing show                  # show routing roles
nanodictate routing set segment <name>    # set segment provider
nanodictate routing set final <name>      # set final provider
nanodictate transcribe FILE [--json]      # one-shot file transcription
nanodictate retry <provider>              # retry last recording
nanodictate last                          # show last transcription
nanodictate logs                          # last 50 log lines
```

The TUI status menu launches automatically when stdout is a TTY. It shows
agent state, provider info, log tail, and supports keyboard navigation
(arrows, Enter, number keys, Esc/q to exit).

### Configuration

Config path: `~/.config/nanodictate/config.toml` (chmod 600, atomic writes).

Example template (created by `nanodictate config init`):

```toml
# Диктовка — конфиг STT-провайдера (создан `nanodictate config init`)
#
# Секреты:
#   - api_key / api_key_file в секции провайдера,
#   - либо env-переменная NANODICTATE_API_KEY (приоритет над файлом —
#     только у активного провайдера; failover-кандидаты и роли сохраняют
#     свои api_key/api_key_file; в конфиг никогда не пишется).
#
# Пустые base_url/model в секциях — агент подставит дефолты адаптера
# (например OpenAI → https://api.openai.com/v1/audio/transcriptions,
# whisper-1; Groq → whisper-large-v3). Для секций
# cookie-relay, cloudflare и открытого OpenAI-совместимого провайдера
# base_url обязателен (cloudflare — полный URL, account_id и модель
# в пути; например .../accounts/<ACCOUNT_ID>/ai/run/@cf/openai/whisper-large-v3-turbo).
#
# Транспорты (ключ transport):
#   direct         — прямой запрос к base_url (по умолчанию)
#   http           — HTTP-прокси: http_proxy = "host:port",
#                    proxy_user / proxy_password (опционально)
#   gateway        — шлюз-ретрансляция с API-ключом в заголовке:
#                    proxy_key + proxy_key_header
#   cookie-relay   — прокси с JS cookie-челленджем (автоматическая
#                    расшифровка AES-128-CBC, не требует ключа)

# Язык STT-подсказки (пусто = авто-детект Whisper, языковой параметр
# в запрос НЕ шлётся). Явное значение (language = "ru") форвардится.
language = ""
ui_language = "en"
sounds_enabled = true
timeout_seconds = 120
log_level = "info"
active_provider = "openai"

[providers.openai]
name = "OpenAI"
base_url = ""
model = ""
api_key = ""

[providers.groq]
name = "Groq"
base_url = ""
model = ""
api_key = ""

[providers.local]
name = "Local"
base_url = ""
model = ""
api_key = ""

[providers.cookie-relay]
name = "Cookie Relay"
base_url = ""
model = ""
api_key = ""
transport = "cookie-relay"
# proxy_key = ""
# proxy_key_header = "X-Proxy-Key"

[providers.cloudflare]
name = "Cloudflare Workers AI"
base_url = ""
model = ""
api_key = ""
transport = "cloudflare"

# Примеры транспортов для секций:
#
# [providers.http-proxy]
# transport = "http"
# http_proxy = "proxy.example.com:8080"
# proxy_user = ""
# proxy_password = ""
#
# [providers.gateway-provider]
# transport = "gateway"
# proxy_key = "your-api-key"
# proxy_key_header = "X-Custom-Auth"

# Маршрутизация STT по ролям: final_provider применяется и в
# чанковом пути (финальный проход по всей записи), и в не-чанковом
# (одиночный прогон). segment_provider — только в чанковом пути
# (сегменты речи), в не-чанковом segment не используется.
# Не задано — роль играет active_provider. Роли (segment/final)
# используют провайдер напрямую — auto_failover на ролях не действует.
# Чтобы включить — раскомментируйте секцию:
#
# [routing]
# segment_provider = "cloudflare"
# final_provider = "groq"
```

Top-level options:

| Key                        | Default       | Meaning                                                                |
|----------------------------|---------------|------------------------------------------------------------------------|
| `active_provider`          | *(first)*     | Which `[providers.<id>]` section is active.                            |
| `providers`                | `[]`          | Explicit failover order, e.g. `["groq", "gigaam"]`.                   |
| `auto_failover`            | `false`       | Retry with the next provider on network/server errors.                 |
| `timeout_seconds`          | `120`         | Timeout for the STT request.                                           |
| `double_alt_max_interval`  | `0.4`         | Max gap between the two Alt presses (seconds).                         |
| `sounds_enabled`           | `true`        | Play system sounds on events.                                          |
| `log_level`                | `"info"`      | `"debug"` enables verbose logging and STT request/response dumps.      |
| `language`                 | `"ru"`        | Spoken language hint sent to the STT API (`""` to omit).               |
| `ui_language`              | `"en"`        | UI language: `"en"` or `"ru"`. Switchable from the TUI menu.           |
| `insert_method`            | `"cgevent"`   | `"cgevent"` or `"clipboard"` (clipboard + Cmd+V).                      |
| `review_before_insert`     | `false`       | Confirm text in terminal before inserting.                             |
| `chunked`                  | `false`       | Chunked/live dictation: segments inserted as you speak.                |
| `undo_max_interval`        | `2.0`         | Window (seconds) for double-Alt undo.                                  |

**Secrets.** API keys go in `api_key` (inline) or `api_key_file` (file
path; first non-empty line is used; `chmod 600`). The environment variable
`NANODICTATE_API_KEY` overrides the file key for the **active provider only**;
failover candidates and routing roles keep their own `api_key`/`api_key_file`.
It is never written to the config file.

### Permissions

On first run, macOS requests permissions. Grant them in **System Settings >
Privacy & Security**:

- **Microphone** — required for audio capture.
- **Accessibility** — required for the global hotkey and text insertion.
- **Input Monitoring** — keyboard-event monitoring (add `NanoDictateAgent` if
  the hotkey does not fire).

Add the *signed* binary (`.build/debug/NanoDictateAgent`) to each list. The
path changes after a rebuild with a different signature — see
[Code Signing](#code-signing).

## Proxy Transports

Each provider can set `transport` in its `[providers.<id>]` section (or at
the top level) to route requests through a proxy.

| Transport        | Config value     | Description                                                                 |
|------------------|------------------|-----------------------------------------------------------------------------|
| Direct           | *(empty / omit)* | No proxy; request goes straight to `base_url`.                              |
| HTTP Proxy       | `"http"`         | Standard HTTP proxy. Uses `http_proxy` (or `https_proxy`) environment      |
|                  |                  | variables. Optional `proxy_user` + `proxy_password` send                   |
|                  |                  | `Proxy-Authorization: Basic ...` header.                                    |
| Gateway          | `"gateway"`      | Secret relay via custom header. Uses `proxy_key` as the header value and    |
|                  |                  | `proxy_key_header` as the header name (default: `X-Proxy-Key`).            |
| Cookie Relay     | `"cookie-relay"` | JS-challenge relay with automatic cookie computation (`__test` cookie via   |
|                  |                  | AES-128-CBC in memory) and periodic renewal.                                |

Legacy aliases `"relay"` and `"infinityfree"` are automatically converted to
`"cookie-relay"` with a deprecation warning.

## UI Language

The TUI and agent UI strings support English and Russian. Set
`ui_language = "en"` or `ui_language = "ru"` in `config.toml` (default:
`"en"`). The first item in the TUI status menu toggles the language at
runtime.

## Development

### Target structure

```
Package.swift                        # swift-tools-version:5.7, macOS 12+
Sources/
  AudioEngineGuard/                  # ObjC clang target (NSException + AVFAudio bridge)
  NanoDictateCore/                     # Core library (Config, STT, AudioService, BatchTranscriber, L10n, …)
  NanoDictateAgent/                     # LaunchAgent executable
  nanodictate/                       # CLI + TUI executable
Tests/
  NanoDictateCoreTests/                # Standalone test runner (no XCTest required)
Resources/
  *.entitlements                     # Code signing entitlements
  *.plist.template                   # LaunchAgent plist template
```

### Running tests

```sh
swift run NanoDictateCoreTests
```

The executable runner enumerates the suite classes in
`Tests/NanoDictateCoreTests/`, runs every `test*` method, prints a summary,
and exits non-zero if any test fails.

## Deploy (MCP Server)

The `mcp/nanodictate-deploy-mcp-server/` directory contains an MCP server
(Model Context Protocol, stdio transport) that automates build, code signing,
and agent restart. It preserves TCC (Microphone/Accessibility) grants by
using a fixed signing identity and fixed entitlements across rebuilds.

Tools provided:

| Tool                | Description                                                          |
|---------------------|----------------------------------------------------------------------|
| `dictation_build`   | `swift build` for the chosen configuration.                          |
| `dictation_sign`    | Re-sign both binaries with the stable identity + entitlements.       |
| `dictation_deploy`  | Build, sign, restart — each step gated on the previous.              |
| `dictation_restart` | Restart the LaunchAgent (`launchctl kickstart -k`).                  |
| `dictation_status`  | Process state, launchd state, code signature details.                |

See [`mcp/nanodictate-deploy-mcp-server/README.md`](mcp/nanodictate-deploy-mcp-server/README.md)
for setup and usage details.

### Code Signing

macOS TCC grants (Microphone, Accessibility, Input Monitoring) are keyed to
the binary's code signature (cdhash). Ad-hoc signing on every rebuild
produces a new signature and resets all grants.

The MCP server uses a fixed identity **"NanoDictate Code Signing"** (a
self-signed certificate created once via Keychain Access > Certificate
Assistant) with fixed entitlements files (`Resources/*.entitlements`) and
`codesign --force --options runtime`. Same identity + same entitlements +
same code = same cdhash = grants survive rebuilds.

To create the signing certificate:

1. Open **Keychain Access** > **Certificate Assistant** > **Create a
   Certificate...**
2. Name: `NanoDictate Code Signing`
3. Identity Type: **Self-Signed Root**
4. Certificate Type: **Code Signing**
5. Create, then sign/redeploy via the MCP server.

`dictation_sign` has **no ad-hoc fallback** — if the identity is missing
from the keychain, it fails with a clear error and points to the steps
above.

## Troubleshooting

- **Agent not running / hotkey dead** — check with `nanodictate status`;
  restart with `nanodictate stop && nanodictate start`. Or use launchctl
  directly:
  ```sh
  launchctl print gui/$(id -u)/com.nanodictate.agent
  launchctl kickstart -k gui/$(id -u)/com.nanodictate.agent
  ```
- **Logs** — `~/Library/Logs/NanoDictate/agent.log`
  (`nanodictate logs` prints the last 50 lines; `tail -f` for live).
  Set `log_level = "debug"` for verbose output; STT request/response
  dumps go to `~/Library/Logs/NanoDictate/transcriber-debug.log`.
- **Permissions re-requested after every rebuild** — binary was re-signed
  with a different identity; use a stable signing certificate (see
  [Code Signing](#code-signing)) and re-grant once.
- **STT timeout / no internet** — check `base_url`, `model`, network
  connection, and proxy transport settings.
- **Config errors** — the agent logs the offending file and line;
  `nanodictate config --show-file` prints parsed config with secrets
  masked.

## Uninstall

```sh
nanodictate stop
rm ~/Library/LaunchAgents/com.nanodictate.agent.plist
rm -rf ~/.config/nanodictate           # config and key files
rm -rf ~/Library/Logs/NanoDictate
rm -f /usr/local/bin/nanodictate     # symlink (if created by the MCP server)
```

## License

[MIT](LICENSE) — Copyright (c) 2026 NanoDictate contributors.
