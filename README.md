# NanoDictate

Lightweight voice dictation for macOS. Double-tap **Alt**, speak, and NanoDictate types the recognized text directly into the app you are already using.

- **~25 MB RAM** in normal background use
- **Works out of the box** with a preconfigured STT provider and model — no API key required
- Types directly into the currently focused macOS app
- **Double-Alt** to start/stop, **Esc** to cancel, quick double-Alt to undo the last insertion
- Stable-signed release builds so Microphone and Accessibility permissions normally persist across upgrades
- OpenAI, Groq, Cloudflare Workers AI, and custom OpenAI-compatible transcription endpoints
- Apple Silicon and Intel
- macOS **12 Monterey or later**
- No Xcode or Swift toolchain required

## Quick start

Install the app with Homebrew Cask:

```bash
brew install --cask kodmial/nanodictate/nanodictate
```

Start the background agent:

```bash
nanodictate start
```

On first use, allow **NanoDictateAgent** in **System Settings → Privacy & Security**:

- **Microphone** — records your voice
- **Accessibility** — inserts recognized text into the focused app

If the global hotkey does not respond, also enable **Input Monitoring**.

Release builds use a stable signing identity, so these permissions are normally granted once and retained across upgrades.

Now use:

```text
Double-Alt   Start recording
Double-Alt   Stop and transcribe
Esc          Cancel
Double-Alt   Immediately after insertion: undo
```

No configuration is required for the default setup.

## Features

- System-wide voice dictation into the focused application
- Global double-Alt hotkey
- Automatic or explicit speech-language selection
- English and Russian interface/language workflow
- Preconfigured keyless STT provider for immediate use
- OpenAI transcription
- Groq transcription
- Cloudflare Workers AI transcription
- Custom OpenAI-compatible endpoints
- Runtime provider switching
- Interactive terminal UI
- One-shot audio-file transcription
- Optional provider failover
- Optional chunked transcription and provider routing
- Optional review before text insertion
- Configurable insertion method, sounds, timeouts, and logging

## Providers

NanoDictate ships with a working default configuration:

| Provider | Default model | API key |
| --- | --- | --- |
| Airubiz | `gigaam-v3-ctc-sherpa` | Not required |
| OpenAI | Provider default / configurable | Required |
| Groq | Provider default / configurable | Required |
| Cloudflare Workers AI | Configurable | Required |

Any supported OpenAI-compatible transcription endpoint can also be configured with a custom `base_url` and `model`.

List providers:

```bash
nanodictate provider list
```

Switch provider:

```bash
nanodictate provider use <id>
```

Set an API key securely:

```bash
nanodictate config set-key <id>
```

## CLI

Run without arguments to open the interactive TUI:

```bash
nanodictate
```

Common commands:

```bash
nanodictate start
nanodictate stop
nanodictate status

nanodictate provider list
nanodictate provider use <id>

nanodictate config init
nanodictate config set-key <id>

nanodictate transcribe FILE
nanodictate logs

nanodictate --help
nanodictate --version
```

`nanodictate transcribe FILE` performs one-shot file transcription without using the global dictation workflow.

## Configuration

The user configuration is stored at:

```text
~/.config/nanodictate/config.toml
```

It is created automatically from the bundled defaults on first launch. Recreate it explicitly with:

```bash
nanodictate config init
```

The full configuration reference is [`config.example.toml`](config.example.toml).

### Core options

| Option | Purpose |
| --- | --- |
| `active_provider` | Active STT provider |
| `language` | STT language hint; empty means automatic detection |
| `ui_language` | UI language |
| `sounds_enabled` | Enable start/stop feedback sounds |
| `timeout_seconds` | STT request timeout |
| `log_level` | Logging verbosity |
| `double_alt_max_interval` | Maximum interval between Alt presses |
| `undo_max_interval` | Time window for quick undo |
| `undo_sound_enabled` | Play feedback for undo |
| `insert_method` | Text insertion method |
| `review_before_insert` | Review transcription before insertion |
| `chunked` | Enable chunked transcription |
| `auto_failover` | Enable provider failover |
| `providers` | Provider list used by failover |

### Provider options

Each provider can define:

```toml
base_url = ""
model = ""
api_key = ""
# api_key_file = "~/.config/nanodictate/keys/provider.txt"
```

For the active provider, `NANODICTATE_API_KEY` can override the configured key without writing it to disk.

Advanced provider configurations can also use transport/proxy settings such as:

```text
transport
http_proxy
proxy_user
proxy_password
proxy_key
proxy_key_header
```

Optional routing can select different providers for chunk segments and the final pass:

```toml
[routing]
segment_provider = "cloudflare"
final_provider = "groq"
```

See [`config.example.toml`](config.example.toml) for the canonical defaults and complete examples.

## Update

```bash
brew update
brew upgrade --cask nanodictate
```

Normal release upgrades keep the same signing identity, so existing Microphone and Accessibility grants should remain valid.

## Uninstall

Stop the background agent first:

```bash
nanodictate stop
brew uninstall --cask nanodictate
```

NanoDictate leaves user data in place:

```text
~/.config/nanodictate/
~/Library/Logs/NanoDictate/
```

Remove those directories manually only if you also want to delete your configuration and logs.

## Alternative installation: MacPorts

NanoDictate is also available through the project MacPorts tree.

Initial installation:

```bash
tmp="$(mktemp)" &&
curl -fsSL https://raw.githubusercontent.com/kodmial/nanodictate/main/scripts/install-macports.sh -o "$tmp" &&
bash "$tmp"
rc=$?
rm -f "$tmp"
exit "$rc"
```

Update:

```bash
sudo port selfupdate
sudo port upgrade nanodictate
```

Uninstall:

```bash
sudo port uninstall nanodictate
```

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md) for build, test, and contribution instructions.

## License

[MIT](LICENSE)
