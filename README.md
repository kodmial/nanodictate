# AltDictation

On-screen dictation for macOS, triggered by a double-tap of the **Alt** key.
Press **Alt** twice, speak, press **Alt** twice again — the recognized text is
typed into whatever app is currently focused.

This project provides three components:

- **DictationCore** — shared library with the core dictation logic
  (recording, STT, overlay, text insertion).
- **DictatorAgent** — background agent (LaunchAgent) that listens for the
  trigger, shows the overlay and does the dictation work.
- **dictatorctl** — command-line control utility (start/stop the agent,
  inspect config, pick providers, transcribe a file, show logs).

## Features

- Double-**Alt** start/stop dictation; **Esc** cancels.
- Overlay panel with live input level, recording/progress/status phases.
- Text is inserted into the focused app via keyboard events (default) or
  via clipboard + Cmd+V (`insert_method = "clipboard"`).
- Undo window: a double-**Alt** shortly after an insertion removes it.
- Multiple STT providers in one config, with failover and manual retry:
  - `auto_failover` — retry with the next provider on network/server errors;
  - `dictatorctl retry <provider>` — re-recognize the last recording with
    another provider.
- Optional review gate (`review_before_insert`) — confirm the text in the
  terminal before it is typed.
- Optional chunked/live dictation (`chunked = true`) — segments are
  recognized and inserted as you speak.
- Speech-to-text is done via OpenAI-compatible audio-transcription endpoints
  (see [Providers](#providers)).

## Requirements

- macOS 12 or newer
- Build tooling: Xcode Command Line Tools (or a Swift toolchain).
  The package targets Swift 5.7 (`Package.swift`, `swift-tools-version:5.7`);
  newer toolchains build it as well.

## Install & Build

```sh
./build.sh
```

The script builds both binaries with `swift build`, re-signs them for
code-signing, and symlinks `dictatorctl` into `/usr/local/bin` (when that
directory is writable) so it works as a plain command.

Environment variables (all optional):

| Variable          | Meaning                                                                                                            |
|-------------------|--------------------------------------------------------------------------------------------------------------------|
| `SWIFT_TOOLCHAIN` | Path to a Swift toolchain, e.g. `~/swift-toolchain/usr`. When set, that toolchain's `swift` is used. Unset — the `swift` from `PATH` is used. |
| `SIGN_IDENTITY`   | Code-signing identity name to use, e.g. `"Local Code Signing"`. Unset — the first valid identity from the login keychain is used automatically. |

### Code signing (important)

Both binaries are **always code-signed** by `build.sh`. macOS privacy
(TCC) grants — Microphone, Accessibility, Input Monitoring — are keyed to
the code signature of the process. With *ad-hoc* signing (or no signing at
all) every rebuild produces a new signature, so the OS forgets your grants
and you have to re-grant the permissions after each rebuild.

To keep grants stable across rebuilds, create a local certificate:

1. Open **Keychain Access** → *Keychain Access* → **Certificate Assistant →
   Create a Certificate…**
2. Name: e.g. `Local Code Signing`
3. **Identity Type**: Self-Signed Root
4. **Certificate Type**: Code Signing
5. Create, then:

```sh
SIGN_IDENTITY="Local Code Signing" ./build.sh
```

If the script finds no valid identity in the keychain, it falls back to
ad-hoc signing, prints a warning, and reminds you how to create the
certificate above.

## Quick start

```sh
# 1. Build (DictatorAgent + dictatorctl; dictatorctl lands in /usr/local/bin)
./build.sh

# 2. Install and start the LaunchAgent
dictatorctl start

# 3. Check the status
dictatorctl status
```

The agent runs even with **no config file** — it falls back to built-in
defaults. To use your own provider, create the config file first (see
[Configuration](#configuration)); the expected path is
`~/.config/dictation/config.toml`
(`dictatorctl config --path` prints it, `dictatorctl config --show-file`
shows its content with secrets masked).

On the first dictation attempt macOS will ask for permissions. If anything
is missing, the agent can't type or record — grant it:

- **Microphone** — System Settings → Privacy & Security → Microphone;
- **Accessibility** — System Settings → Privacy & Security → Accessibility
  (needed for the global hotkey and for text insertion; when missing, the
  agent opens this settings pane itself and waits);
- **Input Monitoring** — System Settings → Privacy & Security → Input
  Monitoring (keyboard-event monitoring on newer macOS; add the
  `DictatorAgent` binary there if the hotkey does not fire).

Add the *signed* binary (`.build/debug/DictatorAgent`) to the corresponding
lists — the path matters, and it changes after a rebuild with a different
signature (see [code signing](#code-signing-important)).

Then just press **Alt** twice, speak, and press **Alt** twice again. Press
**Esc** to cancel. A double-**Alt** right after an insertion undoes it.

## Configuration

Configuration is a small TOML-like file at
`~/.config/dictation/config.toml`. Any line starting with `#` is a comment;
unknown keys are ignored. Minimal example:

```toml
active_provider = "groq"

[providers.groq]
name = "Groq"
base_url = "https://api.groq.com/openai/v1/audio/transcriptions"
model = "whisper-large-v3"
# Prefer a key file (chmod 600) over a literal key:
api_key_file = "~/.config/dictation/keys/groq.txt"
# ...or inline:
# api_key = "gsk_..."
```

Top-level options:

| Key                       | Default | Meaning                                                                                      |
|---------------------------|---------|----------------------------------------------------------------------------------------------|
| `active_provider`         | *(first)* | Which `[providers.<id>]` section is active. If only sections are present and it is unset, the first one wins. |
| `providers`               | `[]`    | Explicit failover order, e.g. `providers = ["groq", "gigaam"]`. Unset — order of sections. |
| `auto_failover`           | `false` | Retry with the next provider when the active one fails on a network/server error. |
| `timeout_seconds`         | `120`   | Timeout for the STT request (capped at ~20 s per request).                                  |
| `double_alt_max_interval` | `0.4`   | Max gap between the two Alt presses that counts as a trigger (seconds).                    |
| `sounds_enabled`          | `true`  | Play system sounds on events.                                                               |
| `log_level`               | `"info"`| `"debug"` enables extra logging and a debug dump of STT requests/responses.                 |
| `language`                | `"ru"`  | Spoken language hint sent to the STT API (leave `""` to omit).                              |
| `insert_method`           | `"cgevent"` | `"cgevent"` — keyboard events; `"clipboard"` — clipboard + Cmd+V (previous clipboard content is restored). |
| `review_before_insert`    | `false` | Print the text to the terminal and wait for Enter before inserting (Esc cancels).           |
| `chunked`                 | `false` | Chunked/live dictation: segments are inserted as you speak.                                 |
| `undo_max_interval`       | `2.0`   | Window (seconds) in which a double-Alt undoes the last insertion.                           |
| `undo_sound_enabled`      | `true`  | Play a sound when an insertion is undone.                                                   |

**Secrets.** Put API keys either inline (`api_key = "…"`) or in a separate
file referenced by `api_key_file` (the first non-empty line is used; the
directory is created with the file, keep it at `chmod 600`). The agent reads
keys from the config file only — stored explicitly, or referenced by path
inside `config.toml`. (Environment variables such as `DICTATION_API_KEY`
are *not* read by the agent.)

## Providers

The agent speaks the **OpenAI audio-transcription protocol**: a
`multipart/form-data` POST to a `/audio/transcriptions` endpoint with
`file` (`audio.wav`), `model` and optional `language`, expecting a JSON
`{"text": "…"}` response. **Any service that exposes such an endpoint works**
— no per-provider code is required. A provider is just a `[providers.<id>]`
section:

```toml
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
base_url = "https://api.deepgram.com/v1/...audio/transcriptions"  # OpenAI-compatible endpoint
model = "nova-2"
api_key_file = "~/.config/dictation/keys/deepgram.txt"

[providers.gigaam]
name = "GigaAM"
base_url = "https://your-gateway/...audio/transcriptions"  # gigaam-v3 compatible gateway
model = "gigaam-v3"
api_key_file = "~/.config/dictation/keys/gigaam.txt"

[providers.local]
name = "Local whisper"
base_url = "http://127.0.0.1:8080/audio/transcriptions"  # whisper.cpp / llama.cpp / faster-whisper server
model = "ggml-large-v3"
api_key = ""
```

Then select the active one:

```sh
dictatorctl provider list
dictatorctl provider use groq
```

### Adding your own provider

Add a `[providers.<id>]` section to `config.toml` with `base_url`, `model`
and either `api_key` or `api_key_file`, set `active_provider` to its id, and
restart the agent (`dictatorctl start`). Optionally set `name` (shown in the
overlay) and `proxy_key` (sent as the `X-Proxy-Key` header).

### Legacy config and relays

A config with no `[providers.X]` sections — the legacy layout with top-level
`base_url` / `model` / `api_key` — still works as-is.

By default every provider is called **directly**. To route a provider through
a relay, set the `transport` key in its section (or at the top level):

```toml
[providers.gigaam]
base_url = "https://your-gateway/.../audio/transcriptions"
model = "gigaam-v3"
transport = "infinityfree"   # built-in cookie-aware relay for this provider
```

An empty/omitted `transport` means a direct request. `"infinityfree"` is the
one built-in relay transport (it handles the relay's JS challenge cookie
transparently); any other value documents a relay label without activating
it. The overlay shows the routing as `relay→provider`.

## Troubleshooting

- **Agent not running / hotkey dead** — check with `dictatorctl status`;
  restart with `dictatorctl stop && dictatorctl start`. Or use launchctl
  directly:
  ```sh
  launchctl print gui/$(id -u)/com.dictation.agent
  launchctl kickstart -k gui/$(id -u)/com.dictation.agent
  ```
- **Logs** —
  `~/Library/Logs/Dictation/agent.log` (tail it with
  `tail -f ~/Library/Logs/Dictation/agent.log`; `dictatorctl logs` prints the
  last 50 lines). Set `log_level = "debug"` for verbose logging; the STT
  request/response debug dump goes to
  `~/Library/Logs/Dictation/transcriber-debug.log`.
- **Permissions re-requested after every rebuild** — the binary was re-signed
  (or ad-hoc signed); macOS forgot the grants. Use a stable signing
  certificate (see [Code signing](#code-signing-important)) and re-grant the
  permissions once.
- **"Таймаут STT" / "Нет интернета"** — network problem or the provider
  endpoint/models are misconfigured; check `base_url`/`model` and the
  internet connection.
- **Config errors** — the agent names the offending file and line in the
  log; `dictatorctl config --show-file` prints the parsed config with
  secrets masked.

## Uninstall

```sh
dictatorctl stop
rm ~/Library/LaunchAgents/com.dictation.agent.plist
rm -rf ~/.config/dictation           # config and key files
rm -rf ~/Library/Logs/Dictation
rm /usr/local/bin/dictatorctl        # symlink created by build.sh
```

## License

[MIT](LICENSE)

## Language note

The UI strings (overlay statuses, CLI help and messages) are currently
**Russian-only** — the project ships with single-language support.