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
brew install kodmial/nanodictate/nanodictate
brew services start kodmial/nanodictate/nanodictate   # start the background dictation agent (outside the sandbox)
```

The first command installs the prebuilt binary (nothing is compiled — no
Xcode needed) and taps `kodmial/homebrew-nanodictate` on the way: the fully
qualified `owner/tap/formula` name resolves the formula without a separate
`brew tap` line — a bare `brew install nanodictate` would not find the formula
unless the tap were already added. The last command registers the background
agent and starts it now and at
every login — it is the explicit activation step, since install alone does
not register the service. `brew services stop kodmial/nanodictate/nanodictate`
stops it.

Prefer an app bundle?

```sh
brew install --cask kodmial/nanodictate/nanodictate
```

Installs **NanoDictate.app** — the same two binaries in a `.app`, background
agent only (no Dock icon). Same single daemon as the formula: one
`~/Library/LaunchAgents/com.nanodictate.agent.plist`, register it once with
`nanodictate start`.

### MacPorts

The port is not in the official MacPorts tree yet, so a bare
`sudo port install nanodictate` does not work on a clean machine. First install
is **one command** — the script registers this repo as a git port source and
installs the same prebuilt binary:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/kodmial/nanodictate/main/scripts/install-macports.sh)
```

The script re-runs itself under `sudo`, clones the canon tree
`kodmial/macports-nanodictate` into `/Users/Shared/macports-nanodictate` —
into a fresh path (an already-present tree is reused only when it is the canon
repo at the pinned revision — origin and revision are verified before the tree
is touched). It then inserts its `file://` source into `sources.conf` (before
`[default]` — first match wins) and installs the port. The port's
`post-activate` registers the
global LaunchAgent and bootstraps it — **the service is alive right after
install**, no `nanodictate start` needed, and it comes back after every reboot
(RunAtLoad + KeepAlive).

Same prebuilt tarball as Homebrew, nothing compiled. After a MacPorts
reinstall the tree in `/Users/Shared` survives while `sources.conf` is
recreated — remove the stale tree (`sudo rm -rf
/Users/Shared/macports-nanodictate`) and run the install command again to
re-clone it and re-register the source.
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

### SWIFT_TOOLCHAIN

The Command Line Tools' SwiftPM manifest API lacks
`PackageDescription.swiftmodule`, so a bare `swift build` cannot parse
`Package.swift` on such machines. Point SwiftPM at a full Swift toolchain
instead (replace `/path/to/full/swift-toolchain` with the path to your full
Swift toolchain — required for SwiftPM; the Xcode command-line tools are not
sufficient):

```sh
export SWIFT_TOOLCHAIN=/path/to/full/swift-toolchain
export SWIFT_EXEC_MANIFEST="$SWIFT_TOOLCHAIN/usr/bin/swiftc"
export SWIFTPM_CUSTOM_LIBS_DIR="$SWIFT_TOOLCHAIN/usr/lib/swift/pm"
swift build -c debug
```

A Node.js MCP server automates build + sign + restart of the agent with a
stable signature (`mcp/nanodictate-deploy-mcp-server/`, see its
[README](mcp/nanodictate-deploy-mcp-server/README.md)). Build locally with a
raw `swift build` only for testing: macOS TCC grants (Microphone,
Accessibility) are keyed to the binary's signature, and an ad-hoc-signed
rebuild changes it, so re-grant the permissions once after such a build.

## Uninstall

**Homebrew** — `nanodictate stop` then `brew uninstall kodmial/nanodictate/nanodictate`
(the plist and config stay behind — remove them by hand if you want them gone).
**Cask** — `brew uninstall --cask kodmial/nanodictate/nanodictate` removes the app only.
**MacPorts** — `nanodictate stop; rm -f ~/Library/LaunchAgents/com.nanodictate.agent.plist`
(`launchctl bootout gui/$(id -u)/com.nanodictate.agent` first if the stop did
not unload it), then `sudo port uninstall nanodictate` — it boots out the agent
and removes the global plist in one command. What stays behind: your config
(`~/.config/nanodictate/`), your logs (`~/Library/Logs/NanoDictate/`), and —
unless removed by the `rm` above — the user LaunchAgent plist, whose `KeepAlive`
keeps relaunching the removed binary.

## License

[MIT](LICENSE) — Copyright (c) 2026 NanoDictate contributors.