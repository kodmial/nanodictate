# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-09-19

### Added

- Dictation started/stopped by a double **Alt** press; **Esc** cancels.
- Overlay panel with live input level and recording/progress/status phases.
- Bilingual UI (English and Russian), switchable from the TUI menu.
- Text insertion via CGEvent keyboard events (default) or clipboard + Cmd+V
  (previous clipboard restored).
- Undo window: a double-**Alt** shortly after an insertion removes the text.
- Silence auto-stop (~3 s of quiet) with configurable duration and RMS
  threshold (`NANODICTATE_AUTOSTOP_DURATION`, `NANODICTATE_AUTOSTOP_RMS`).
- Multi-provider STT via OpenAI-compatible `/audio/transcriptions` adapters:
  OpenAI, Groq, GigaAM (default batch provider), local whisper/llama.cpp/
  faster-whisper, Cloudflare Workers AI, Cookie Relay, and any generic
  `openai-compatible` endpoint.
- Proxy transports: direct, HTTP proxy, gateway (`proxy_key` header relay),
  and cookie-relay (JS-challenge with computed `__test` cookie).
- Batch file transcription: chunked segments, parallel workers, pause cutting,
  checkpoint/resume, and a progress bar.
- Optional review gate (`review_before_insert`) — confirm text before typing.
- Auto-failover between providers and manual `nanodictate retry <provider>`.
- Interactive TUI status menu (`nanodictate`) with agent state, provider list,
  log viewer, and language toggle.
- Background LaunchAgent (`com.nanodictate.agent`) with
  `nanodictate start|stop|status`.
- TOML configuration at `~/.config/nanodictate/config.toml`
  (chmod 600, atomic writes).
- Code signing workflow with a stable identity + fixed entitlements to preserve
  macOS TCC grants (Microphone/Accessibility) across rebuilds.
- `nanodictate --version` / `-v` prints the current version.

[Unreleased]: https://github.com/kodmial/nanodictate/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/kodmial/nanodictate/releases/tag/v0.1.0