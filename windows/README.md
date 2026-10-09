# Windows host (bootstrap stage)

First native Windows host for NanoDictate on the **same production Rust
core used by macOS** (`rust/nanodictate-core` through its stable C ABI).

This is the bootstrap stage only: it proves the ABI handshake, memory
ownership, strings/buffers, error propagation, and representative
stateful handles from C#. It is not a full product: no audio capture,
global hotkeys, text insertion, UI polish, installer, or feature-parity
claim yet.

## Layout

```text
windows/
  NanoDictate.sln
  src/NanoDictate.Core/    # thin P/Invoke adapter, no product logic
  src/NanoDictate.Smoke/   # minimal executable smoke path
  tests/NanoDictate.Core.Tests/  # xUnit ABI/ownership/error/session tests
```

`NanoDictate.Core` owns no behavior. Every wrapper marshals arguments,
calls exactly one `nd_*` entry point, maps the stable error code plus
`nd_last_error_text`, and releases Rust-owned allocations with the
matching `nd_string_free` / `nd_bytes_free` / `*_free` function.
Failover ordering, backoff math, VAD thresholds, transcript rules, and
session semantics stay in Rust.

Portable configuration (`PortableConfig`) only carries data parsed from
the shared TOML shape (`config.example.toml`); all policy decisions go
through `NanoEngine` into Rust.

## Prerequisites

- Windows 10 22H2 or Windows 11, x64.
- .NET 8 SDK or later.
- Rust stable with the MSVC target (`rustup target add x86_64-pc-windows-msvc`).

## Local build

```powershell
# From the repository root:
cargo build --release -p nanodictate-core
dotnet build windows/NanoDictate.sln -c Release
dotnet test windows/NanoDictate.sln -c Release
dotnet run --project windows/src/NanoDictate.Smoke -c Release -- config.example.toml
```

The loader resolves the engine in this order: `NANODICTATE_CORE_DLL`
environment variable, app directory, `rust/target/release/`, then the
default OS search. CI copies the freshly built
`nanodictate_core.dll` next to the managed binaries before running
tests and the smoke executable.

## Supported scope

- Windows x64 desktop. ARM64 is not packaged in this stage.
- The Rust `cdylib` is built with the MSVC target; no Windows-specific
  behavior was added to the Rust core for this stage.
