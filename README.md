# NanoDictate

Live voice dictation into any macOS app (12+). Double-tap **Alt** to start and
stop — speak, and the recognized text is typed into the currently focused app.
STT runs on OpenAI, Groq, Cloudflare Workers AI, or any OpenAI-compatible
endpoint. Dev binaries deployed via the MCP server are signed with a stable
identity, so **Microphone/Accessibility grants survive rebuilds**; release
binaries replaced by an update may ask for the grants again.

## Installation

### Homebrew

```sh
brew install kodmial/nanodictate-homebrew/nanodictate
```

Binary formula — downloads a prebuilt tarball, nothing is compiled. The tap is
not published yet (see GitHub Releases below).

### MacPorts

```sh
sudo port install nanodictate
```

Builds from source (Xcode 14.3+, use_xcode yes; first build is long). The port
is pending upstream acceptance — use GitHub Releases below.

### GitHub Releases (current)

```sh
curl -L -O https://github.com/kodmial/nanodictate/releases/download/v0.1.0/nanodictate-0.1.0-macos-$(uname -m).tar.gz
tar xzf nanodictate-0.1.0-macos-$(uname -m).tar.gz
mkdir -p ~/.local/bin
cp NanoDictateAgent nanodictate ~/.local/bin/
nanodictate start
```

The archive contains the two binaries plus `config.example.toml` (the first
launch copies it to the config path automatically). Browser downloads get a
`com.apple.quarantine` attribute — clear it once with
`xattr -dr com.apple.quarantine ~/.local/bin/NanoDictateAgent ~/.local/bin/nanodictate`.

## Configuration

Config lives at `~/.config/nanodictate/config.toml` (chmod 600, atomic
writes). `nanodictate config init` — auto-run on first launch — copies the
bundled `config.example.toml`, the single source of defaults. Edit the user
config, not that file.

Top-level options (defaults):

```toml
language = ""          # STT hint; empty = Whisper auto-detect
ui_language = "en"
sounds_enabled = true
timeout_seconds = 120
log_level = "info"
active_provider = "airubiz"    # openai / groq / cloudflare / airubiz / any custom id
```

Provider sections: key via `api_key` or `api_key_file`:

```toml
[providers.openai]
name = "OpenAI"
base_url = ""          # empty = adapter defaults
model = ""
api_key = ""           # e.g. "gsk_..." (Groq)
# api_key_file = "~/.config/nanodictate/keys/openai.txt"
```

`airubiz` is the only section with non-empty `base_url`/`model` — anonymous
keyless STT, the default (transport `direct`):

```toml
[providers.airubiz]
name = "Airubiz"
base_url = "https://api.airubiz.site/v1/audio/transcriptions"
model = "gigaam-v3-ctc-sherpa"
api_key = ""
```

`transport` in a provider's section picks how the request reaches the server
(see [Transports](#transports)):

```toml
transport = "http"
http_proxy = "proxy.example.com:8080"
```

- Any OpenAI-compatible endpoint: custom section id, set `base_url` + `model`
  explicitly (`openai`/`groq` get adapter defaults).
- Secrets live in `api_key`/`api_key_file`; `NANODICTATE_API_KEY` overrides
  the file for the active provider only and is never written to disk.

Full list of sections and options — see [config.example.toml](config.example.toml).

## Usage

```sh
nanodictate start | stop | status
nanodictate config init           # create config.toml from the bundled example
nanodictate config set-key <id>   # set an API key interactively
nanodictate provider use <id>     # switch active provider
nanodictate transcribe FILE       # one-shot file transcription
nanodictate logs                  # last 50 log lines
```

Run `nanodictate` with no arguments for the interactive TUI (status, provider
list, log viewer, EN/RU language toggle). Dictation: double-**Alt** start,
speak, double-**Alt** stop (**Esc** cancels); a double-**Alt** shortly after an
insertion undoes it. `nanodictate start` registers the LaunchAgent
(`com.nanodictate.agent`). Grant **Microphone** and **Accessibility** to
`NanoDictateAgent` in System Settings once (add **Input Monitoring** if the
hotkey does not fire).

## Providers

| id | Provider | Key |
|---|---|---|
| `openai` | Whisper API | api_key |
| `groq` | Whisper (fast) | api_key |
| `cloudflare` | Workers AI, raw WAV; `base_url` = full URL incl. `account_id`/model | api_key |
| `airubiz` | GigaAM, anonymous (**default**) | none |
| any other id | generic OpenAI-compatible endpoint | per server |

Default `active_provider = "airubiz"` (zero-config; no key needed). Unknown
ids fall back to the generic OpenAI-compatible adapter.

## Transports

`transport` in a provider's section decides how requests reach the STT server:

| transport | Fields | When |
|---|---|---|
| `direct` (default) | `base_url`, `api_key` | direct HTTPS |
| `http` | `http_proxy = host:port`, optional `proxy_user`/`proxy_password` | via HTTP proxy (Basic auth) |
| `gateway` | `proxy_key`, optional `proxy_key_header` (default `X-Proxy-Key`) | secret header; active when `proxy_key` non-empty |
| `cookie-relay` | `base_url`, optional `proxy_key` | JS-challenge relay (`__test` cookie, AES-128-CBC, TTL 120s) |

Notes: `cloudflare` is a provider id, **not** a transport; `cookie-relay` is a
**transport value, not a provider** — set `transport = "cookie-relay"` inside
any STT provider's section.

## Code Signing & TCC

macOS TCC grants are keyed to the binary's signature (cdhash). The stable
identity **NanoDictate Code Signing** keeps the cdhash stable across dev
rebuilds, so grants survive — this applies only to binaries deployed via the
MCP server (`mcp/nanodictate-deploy-mcp-server`, `dictation_sign` /
`dictation_deploy`); raw `swift build` + ad-hoc `codesign` changes the
signature and drops Microphone/Accessibility grants. Release binaries are
ad-hoc signed: after an update replaces the binary, macOS may ask for
Microphone/Accessibility grants again — re-grant them once.

## Build & Test

```sh
swift build -c debug                          # or -c release
swift run nanodictate --help
swift run NanoDictateCoreTests                # standalone runner, 795 tests
```

## MCP Server

`mcp/nanodictate-deploy-mcp-server/` automates build + sign + restart of the
agent with a stable signature (Node.js ≥ 22). See its
[README](mcp/nanodictate-deploy-mcp-server/README.md).

## Troubleshooting

- Agent dead / hotkey gone: `nanodictate stop && nanodictate start`.
- Permissions re-requested after a dev rebuild: re-sign with the stable
  identity (`dictation_deploy`) and re-grant once; after a release update
  replaces the binary, macOS re-prompts — just re-grant the permissions
  again.
- Logs: `~/Library/Logs/NanoDictate/agent.log`; set `log_level = "debug"` for
  verbose output (`nanodictate logs` prints the last 50 lines).

## Uninstall

**Homebrew**

```sh
nanodictate stop
brew uninstall kodmial/nanodictate-homebrew/nanodictate
```

**MacPorts**

```sh
nanodictate stop
sudo port uninstall nanodictate
```

User files (config, logs, LaunchAgent) survive the package uninstall — remove
manually:

```sh
rm ~/Library/LaunchAgents/com.nanodictate.agent.plist
rm -rf ~/.config/nanodictate ~/Library/Logs/NanoDictate
```

## License

[MIT](LICENSE) — Copyright (c) 2026 NanoDictate contributors.