# Portable STT configuration parity

This document is the delta matrix between the macOS Swift host and the
Windows C# host for the shared TOML shape (`config.example.toml`) and the
common STT request contract. The shared Rust engine remains the owner of
model profiles/defaults, transcript parsing, failover/backoff policy, and
related deterministic decisions. Swift and C# keep native networking,
multipart framing, file streaming, paths, and OS credentials.

Cross-platform regression vectors live in
`Tests/Fixtures/portable-parity.json`. Both production loaders and both
production request builders consume that fixture:

- Swift: `Tests/NanoDictateCoreTests/PortableParityTests.swift`
- Windows: `windows/tests/NanoDictate.Core.Tests/PortableParityTests.cs`

Tests use fake transports/request plans only; they never contact a provider.

## Configuration keys

| Key | macOS | Windows | Parity decision |
| --- | --- | --- | --- |
| `active_provider` | Read; unknown id throws during load | Read; unknown id throws when the catalog selects it | Shared fixture for valid ids; permissive loader noted below |
| `language` | Read; empty omits the language hint | Read; same request gating | Shared fixture |
| `prompt` | Read; gated by profile support | Read; gated by profile support | Shared fixture |
| `[providers.X] name` | Read | Read | Shared fixture |
| `[providers.X] base_url` | Read; empty uses Rust adapter default | Read; empty uses Rust adapter default | Shared fixture |
| `[providers.X] model` | Read; empty uses Rust adapter default | Read; empty uses Rust adapter default | Shared fixture + request fixture |
| `[providers.X] api_key` | Read per provider | Read per provider (was ignored before #214) | Shared fixture |
| `[providers.X] api_key_file` | First non-empty, non-comment line; `~` expanded | Same, plus environment-variable expansion and normalized path | Shared fixture |
| `[routing] segment_provider` | Read; unknown falls back to active | Read; role catalog retains configured id | Shared fixture for valid ids; unknown-id fallback intentionally differs |
| `[routing] final_provider` | Read; unknown falls back to active | Read; role catalog retains configured id | Shared fixture for valid ids; unknown-id fallback intentionally differs |
| top-level `providers = [...]` | Explicit failover order; deduplicated/skips unknown | Explicit failover order; deduplicated/skips unknown (was ignored before #214) | Shared fixture |
| `auto_failover` | Read | Read | Existing product tests |
| `timeout_seconds` | Read | Read | Existing product tests |
| `chunked`, `chunked_final_pass` | Read | Read | Existing product tests |
| `insert_method`, `double_alt_max_interval`, `undo_max_interval`, `review_before_insert` | Read | Read (`cgevent` maps to Direct) | Existing product tests |
| top-level `transport`, `http_proxy`, `proxy_user`, `proxy_password`, `proxy_key`, `proxy_key_header` | Read | Read | Existing product tests |

### Secret precedence (active vs role/failover)

Both hosts implement the same request-time contract:

1. `NANODICTATE_API_KEY` applies only to the effective active provider.
2. An empty `active_provider` makes the first declared provider active.
3. Every other provider (failover candidate or `[routing]` role) keeps its
   own `api_key`, then its own `api_key_file`.
4. A keyless provider (for example the default Airubiz config) sends no
   `Authorization` header.
5. Secrets are never written to logs, diagnostics, config output, or the Rust
   ABI. Windows `ProviderEntry.ToString()` prints only `empty`/`redacted` and
   `none`/`configured` markers.

Malformed key files, missing files, and unreadable paths resolve to an empty
key instead of failing the host. Values are never logged.

## STT request behavior (common subset)

| Behavior | macOS owner | Windows owner | Status |
| --- | --- | --- | --- |
| Resolve base URL/model defaults | Rust `nd_stt_resolve` + native adapter | Rust `nd_stt_resolve`/`nd_stt_default_model` + native adapter | Same defaults; fixture covers OpenAI, Groq, and keyless custom |
| Model profile capabilities | Rust | Rust | Same |
| Multipart model/prompt fields | Native `ProviderRequestBuilder` gated by Rust profile | Native `SttRequestBuilder` gated by Rust profile | Shared request fixture |
| Language hint | Rust `language_hint` (`none`/`single`/`multi`) | Rust `language_hint` (`none`/`single`/`multi`) | Same for the primary language |
| Segment word timestamps | `verbose_json` + word granularity only where the profile allows | Same gating | Shared request fixture |
| Keyless authorization | Native request omits empty `Bearer ` | Native plan omits empty authorization | Shared request fixture (macOS outer request layer removes the empty header) |
| Transcript parsing | Rust `nd_transcript_parse` | Rust `nd_transcript_parse` | Existing engine vectors |
| Retry/failover order and backoff | Rust | Rust | Existing engine vectors + fixture order |
| Cancellation/error classification | Rust kind gate + native async | Rust kind gate + native async | Existing product tests |

## Intentional platform/feature differences

These are not compared as common behavior and are not silently emulated on
Windows:

- **Per-provider transport/proxy overrides** (`transport`, `http_proxy`,
  `proxy_*` inside `[providers.X]`): macOS applies them per section. The
  Windows host keeps one top-level `TransportConfig`; per-provider overrides
  are not supported and are ignored. Use top-level Windows transport settings
  or provider sections without those fields.
- **`cookie-relay` transport**: macOS only (JS challenge/cookie solver).
  Windows rejects it loudly.
- **`upload_format` / FLAC / file-backed uploads**: macOS supports capability-
  gated FLAC and file-backed multipart bodies. Windows uses in-memory WAV
  multipart and ignores `upload_format` (never labels WAV bytes as another
  format).
- **`vocabulary`, `extra_languages`, contextual-bias batch fields**: macOS
  folds these into capability-gated request fields. Windows currently ignores
  them rather than sending unsupported fields.
- **Cloudflare raw-audio adapter**: Rust resolves the profile and macOS sends
  raw WAV; the Windows request builder supports the shared multipart subset
  only. Keep a configured Cloudflare provider for macOS or use an
  OpenAI-compatible multipart provider on Windows.
- **macOS UI/lifecycle keys** (`ui_language`, `sounds_enabled`, `log_level`,
  `undo_sound_enabled`) are not Windows host policy.
- **Strict TOML errors**: macOS rejects malformed lines and duplicate provider
  sections. The Windows portable loader is intentionally permissive for
  unknown/malformed lines it does not consume, so existing Windows configs
  keep loading. The shared fixtures compare only keys both hosts advertise.

## Issue #214 before/after

| Area | Before | After | Owner |
| --- | --- | --- | --- |
| Windows per-provider `api_key` | Ignored | Parsed and used for the matching provider | Windows config/host |
| Windows per-provider `api_key_file` | Ignored | Parsed, expanded, and read on request | Windows config/host |
| Windows env precedence | Applied to every provider when `active_provider` was empty | Applied only to the effective active provider | Windows host |
| Windows role/failover credentials | Always empty | Each provider resolves its own configured secret | Windows host |
| Windows explicit `providers` order | Ignored | Drives catalog failover order | Windows config/catalog |
| Windows empty configured model | Omitted from requests | Resolves through Rust to the adapter default (for example `gpt-transcribe`) | Windows request builder |
| Cross-platform regression oracles | Separate platform tests only | Shared JSON vectors for config, keys, order, and request fields | Swift + Windows tests |

No Rust ABI, macOS behavior, or native networking ownership changed in this
issue.
