# AltDictation

On-screen dictation for macOS, triggered by a double-tap of the **Alt** key.
Press **Alt** twice, speak, press **Alt** twice again — the recognized text is
typed into whatever app is currently focused.

Built as a Swift Package Manager package (`swift-tools-version:5.7`, macOS 12+).

## Components

- **DictationCore** — shared library with the core dictation logic (recording,
  STT, overlay, text insertion, provider adapters, silence auto-stop, batch
  transcription).
- **DictatorAgent** — background LaunchAgent daemon that listens for the
  trigger, shows the overlay, and performs the dictation work.
- **dictatorctl** — command-line control utility and interactive TUI status
  menu (start/stop the agent, inspect config, pick providers, transcribe
  files, show logs).

## Features

- Double-**Alt** start/stop dictation; **Esc** cancels.
- Interactive TUI status menu (`dictatorctl`) with agent state, provider list,
  log viewer, and language toggle as the first menu item.
- Bilingual UI (English and Russian); set `ui_language = "en"` or `"ru"` in
  config (default: `"en"`).
- Overlay panel with live input level, recording/progress/status phases.
- Text insertion via CGEvent keyboard events (default) or clipboard + Cmd+V
  (`insert_method = "clipboard"`, restores previous clipboard).
- Undo window: a double-**Alt** shortly after an insertion removes it.
- Silence auto-stop (~3 s of quiet) with configurable duration and RMS
  threshold; environment variables
  `DICTATION_AUTOSTOP_DISABLED`, `DICTATION_AUTOSTOP_DURATION`,
  `DICTATION_AUTOSTOP_RMS`.
- Push-to-talk mode (external script: `ptt.sh`).
- Batch file transcription with chunked segments, parallel workers, pause
  cutting, checkpoint/resume, and a progress bar.
- Multi-provider STT via adapters implementing the OpenAI-compatible
  `/audio/transcriptions` protocol:
  - **OpenAI** (`openai`)
  - **Groq** (`groq`)
  - **Deepgram** (`deepgram`)
  - **GigaChat** (`giga-chat`, OAuth with `api_secret`)
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
  (`dictatorctl retry <provider>`).
- TOML configuration at `~/.config/dictation/config.toml`.

## Build & Test

Requirements: macOS 12+, Swift toolchain (Xcode CLT or standalone).

```sh
swift build -c release
```

Run the test suite (659 tests):

```sh
zsh /private/tmp/dct-verify/build_all.sh
```

The test runner is a standalone executable target (`DictationCoreTests`) that
replaces `swift test` (which does not work without XCTest in this project
layout). Individual tests can also be run with
`swift run DictationCoreTests`.

## Install & Run

### LaunchAgent (DictatorAgent)

```sh
# Install and start the LaunchAgent
dictatorctl start

# Check status
dictatorctl status

# Stop the agent
dictatorctl stop
```

The agent installs a plist template (`Resources/dictation-agent.plist.template`)
as `~/Library/LaunchAgents/com.dictation.agent.plist` and bootstraps it into
`launchd`. The `start` command is idempotent.

### CLI & TUI (dictatorctl)

```sh
dictatorctl start | stop | status
dictatorctl config init [--force]         # create default config.toml
dictatorctl config path                   # show config path
dictatorctl config set-key <provider>     # set API key interactively
dictatorctl provider list                 # list configured providers
dictatorctl provider use <name>           # set active provider
dictatorctl routing show                  # show routing roles
dictatorctl routing set segment <name>    # set segment provider
dictatorctl routing set final <name>      # set final provider
dictatorctl transcribe FILE [--json]      # one-shot file transcription
dictatorctl retry <provider>              # retry last recording
dictatorctl last                          # show last transcription
dictatorctl logs                          # last 50 log lines
```

The TUI status menu launches automatically when stdout is a TTY. It shows
agent state, provider info, log tail, and supports keyboard navigation
(arrows, Enter, number keys, Esc/q to exit).

### Configuration

Config path: `~/.config/dictation/config.toml` (chmod 600, atomic writes).

Example template (created by `dictatorctl config init`):

```toml
# active_provider = "openai"

[providers.openai]
name = "OpenAI"
base_url = "https://api.openai.com/v1/audio/transcriptions"
model = "whisper-1"
api_key_file = "~/.config/dictation/keys/openai.txt"

[providers.groq]
name = "Groq"
base_url = "https://api.groq.com/openai/v1/audio/transcriptions"
model = "whisper-large-v3"
api_key_file = "~/.config/dictation/keys/groq.txt"

[providers.deepgram]
name = "Deepgram"
base_url = "https://api.deepgram.com/v1/listen"
model = "nova-3"
api_key_file = "~/.config/dictation/keys/deepgram.txt"

[providers.giga-chat]
name = "GigaChat"
base_url = "https://your-gigachat-endpoint.example.com/api/v1/audio/transcriptions"
model = "GigaChat"
api_key_file = "~/.config/dictation/keys/giga-chat.txt"
api_secret = ""

[providers.local]
name = "Local whisper"
base_url = "http://127.0.0.1:8080/v1/audio/transcriptions"
model = "whisper-1"
api_key = ""

[providers.cookie-relay]
name = "Cookie Relay"
base_url = "https://proxy.example.com/audio/transcriptions"
model = "whisper-large-v3"
transport = "cookie-relay"
proxy_key = ""
proxy_key_header = "X-Proxy-Key"

[providers.cloudflare]
name = "Cloudflare"
base_url = "https://api.cloudflare.com/client/v4/accounts/<ACCOUNT_ID>/ai/run/@cf/openai/whisper-large-v3-turbo"
model = ""
# transport = "cloudflare"
# api_key = ""

# [routing]
# segment_provider = ""
# final_provider = ""
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
`DICTATION_API_KEY` overrides both and is never written to the config file.
Provider-specific: `api_secret` is used for GigaChat OAuth.

### Permissions

On first run, macOS requests permissions. Grant them in **System Settings >
Privacy & Security**:

- **Microphone** — required for audio capture.
- **Accessibility** — required for the global hotkey and text insertion.
- **Input Monitoring** — keyboard-event monitoring (add `DictatorAgent` if
  the hotkey does not fire).

Add the *signed* binary (`.build/debug/DictatorAgent`) to each list. The
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
`ui_language = "en"` or `"ui_language = "ru"` in `config.toml` (default:
`"en"`). The first item in the TUI status menu toggles the language at
runtime.

## Development

### Target structure

```
Package.swift                        # swift-tools-version:5.7, macOS 12+
Sources/
  AudioEngineGuard/                  # ObjC clang target (NSException + AVFAudio bridge)
  DictationCore/                     # Core library (Config, STT, AudioService, BatchTranscriber, L10n, …)
  DictatorAgent/                     # LaunchAgent executable
  dictatorctl/                       # CLI + TUI executable
Tests/
  DictationCoreTests/                # Standalone test runner (659 tests)
Resources/
  *.entitlements                     # Code signing entitlements
  *.plist.template                   # LaunchAgent plist template
```

### Running tests

```sh
zsh /private/tmp/dct-verify/build_all.sh
```

Or run the test executable directly:

```sh
swift run DictationCoreTests
```

## Deploy (MCP Server)

The `mcp/dictation-deploy-mcp-server/` directory contains an MCP server
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

See [`mcp/dictation-deploy-mcp-server/README.md`](mcp/dictation-deploy-mcp-server/README.md)
for setup and usage details.

### Code Signing

macOS TCC grants (Microphone, Accessibility, Input Monitoring) are keyed to
the binary's code signature (cdhash). Ad-hoc signing on every rebuild
produces a new signature and resets all grants.

The MCP server uses a fixed identity **"Dictation Code Signing"** (a
self-signed certificate created once via Keychain Access > Certificate
Assistant) with fixed entitlements files (`Resources/*.entitlements`) and
`codesign --force --options runtime`. Same identity + same entitlements +
same code = same cdhash = grants survive rebuilds.

To create the signing certificate:

1. Open **Keychain Access** > **Certificate Assistant** > **Create a
   Certificate...**
2. Name: `Dictation Code Signing`
3. Identity Type: **Self-Signed Root**
4. Certificate Type: **Code Signing**
5. Create, then sign/redeploy via the MCP server.

`dictation_sign` has **no ad-hoc fallback** — if the identity is missing
from the keychain, it fails with a clear error and points to the steps
above.

## Troubleshooting

- **Agent not running / hotkey dead** — check with `dictatorctl status`;
  restart with `dictatorctl stop && dictatorctl start`. Or use launchctl
  directly:
  ```sh
  launchctl print gui/$(id -u)/com.dictation.agent
  launchctl kickstart -k gui/$(id -u)/com.dictation.agent
  ```
- **Logs** — `~/Library/Logs/Dictation/agent.log`
  (`dictatorctl logs` prints the last 50 lines; `tail -f` for live).
  Set `log_level = "debug"` for verbose output; STT request/response
  dumps go to `~/Library/Logs/Dictation/transcriber-debug.log`.
- **Permissions re-requested after every rebuild** — binary was re-signed
  with a different identity; use a stable signing certificate (see
  [Code Signing](#code-signing)) and re-grant once.
- **STT timeout / no internet** — check `base_url`, `model`, network
  connection, and proxy transport settings.
- **Config errors** — the agent logs the offending file and line;
  `dictatorctl config --show-file` prints parsed config with secrets
  masked.

## Uninstall

```sh
dictatorctl stop
rm ~/Library/LaunchAgents/com.dictation.agent.plist
rm -rf ~/.config/dictation           # config and key files
rm -rf ~/Library/Logs/Dictation
rm -f /usr/local/bin/dictatorctl     # symlink (if created by the MCP server)
```

## License

[MIT](LICENSE) — Copyright (c) 2026 AltDictation contributors.
