#!/usr/bin/env bash
# Shared toolchain library for the adaptive cached bootstrap.
#
# Sourceable from scripts and GitHub Actions steps:
#   source scripts/toolchain/toolchain.sh
#
# All key derivation is pure and deterministic: given the same manifest,
# runner OS/architecture, and lockfile hashes, the same cache keys are
# produced on any host without network access. Production jobs restore
# immutable caches first and install only on cache miss.

set -uo pipefail

TOOLCHAIN_MANIFEST_DEFAULT=".github/toolchain.json"

# toolchain_manifest_value <manifest> <jq-filter> [fallback]
# Reads one scalar from the manifest with jq when available, otherwise a
# small python3 fallback (python3 ships on all GitHub-hosted runners).
toolchain_manifest_value() {
  local manifest=${1:-$TOOLCHAIN_MANIFEST_DEFAULT} filter=${2:-} fallback=${3:-}
  if [[ ! -f "$manifest" ]]; then
    printf '%s' "$fallback"
    return 0
  fi
  if command -v jq >/dev/null 2>&1; then
    jq -r "$filter // empty" "$manifest" 2>/dev/null || printf '%s' "$fallback"
  elif command -v python3 >/dev/null 2>&1; then
    TOOLCHAIN_MANIFEST_PATH="$manifest" TOOLCHAIN_FILTER="$filter" python3 -c "
import json, os
try:
    with open(os.environ['TOOLCHAIN_MANIFEST_PATH']) as fh:
        data = json.load(fh)
    node = data
    for part in os.environ['TOOLCHAIN_FILTER'].lstrip('.').split('.'):
        if isinstance(node, dict):
            node = node.get(part)
        else:
            node = None
            break
    print(node if isinstance(node, str) else '')
except Exception:
    print('')
" 2>/dev/null || printf '%s' "$fallback"
  else
    printf '%s' "$fallback"
  fi
}

# toolchain_normalize_os <runner-os|uname-s>
# Maps GitHub runner.os values and uname tokens to cache-stable identifiers.
# Windows variants map to "windows" so a future Windows job gets distinct
# platform caches without changing the key architecture.
toolchain_normalize_os() {
  local raw=${1:-}
  local lower
  lower=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    macos|darwin|mac*) printf 'macos' ;;
    linux|ubuntu*) printf 'linux' ;;
    windows*|mingw*|msys*|win32|win64) printf 'windows' ;;
    *) printf '%s' "$lower" ;;
  esac
}

# toolchain_normalize_arch <runner-arch|uname-m>
toolchain_normalize_arch() {
  local raw=${1:-}
  local lower
  lower=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    arm64|aarch64) printf 'arm64' ;;
    x86_64|x64|amd64) printf 'x64' ;;
    *) printf '%s' "$lower" ;;
  esac
}

# toolchain_detect_platform [os-override] [arch-override]
# Prints "<os> <arch>" using GitHub runner context when present, else uname.
toolchain_detect_platform() {
  local os arch
  os=${1:-${RUNNER_OS:-}}
  arch=${2:-${RUNNER_ARCH:-}}
  if [[ -z "$os" ]]; then
    os=$(uname -s 2>/dev/null || printf 'unknown')
  fi
  if [[ -z "$arch" ]]; then
    arch=$(uname -m 2>/dev/null || printf 'unknown')
  fi
  # GitHub RUNNER_ARCH uses X86/X64/ARM64 spellings.
  printf '%s %s\n' "$(toolchain_normalize_os "$os")" "$(toolchain_normalize_arch "$arch")"
}

# toolchain_file_hash <paths...>
# Stable short hash of file contents for cache-key inputs. Missing files
# contribute a constant token so keys stay well-formed before Rust exists.
toolchain_file_hash() {
  local paths=("$@")
  local existing=()
  local p
  for p in "${paths[@]}"; do
    if [[ -f "$p" ]]; then
      existing+=("$p")
    fi
  done
  if [[ ${#existing[@]} -eq 0 ]]; then
    printf 'no-inputs'
    return 0
  fi
  if command -v shasum >/dev/null 2>&1; then
    cat "${existing[@]}" | shasum -a 256 | cut -c1-16
  elif command -v sha256sum >/dev/null 2>&1; then
    cat "${existing[@]}" | sha256sum | cut -c1-16
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c "
import hashlib, sys
h = hashlib.sha256()
for path in sys.argv[1:]:
    with open(path, 'rb') as fh:
        h.update(fh.read())
print(h.hexdigest()[:16])
" "${existing[@]}"
  else
    cksum "${existing[@]}" | awk '{print $1}'
  fi
}

# toolchain_rust_inputs_hash [repo-root]
# Hash of exactly the inputs that materially affect Cargo caches:
# rust-toolchain files, Cargo.lock, Cargo.toml manifests, and .cargo config.
# Never hashes the whole source tree, so routine edits do not churn caches.
toolchain_rust_inputs_hash() {
  local root=${1:-.}
  local candidates=()
  [[ -f "$root/rust-toolchain.toml" ]] && candidates+=("$root/rust-toolchain.toml")
  [[ -f "$root/rust-toolchain" ]] && candidates+=("$root/rust-toolchain")
  [[ -f "$root/Cargo.lock" ]] && candidates+=("$root/Cargo.lock")
  while IFS= read -r f; do
    candidates+=("$f")
  done < <(find "$root" -maxdepth 3 -name 'Cargo.toml' -not -path '*/target/*' 2>/dev/null | sort)
  [[ -f "$root/.cargo/config.toml" ]] && candidates+=("$root/.cargo/config.toml")
  if [[ ${#candidates[@]} -eq 0 ]]; then
    printf 'no-rust-inputs'
    return 0
  fi
  toolchain_file_hash "${candidates[@]}"
}

# toolchain_swift_inputs_hash [repo-root]
# Hash of the Swift package graph inputs (Package.swift + Package.resolved).
toolchain_swift_inputs_hash() {
  local root=${1:-.}
  local candidates=()
  [[ -f "$root/Package.swift" ]] && candidates+=("$root/Package.swift")
  [[ -f "$root/Package.resolved" ]] && candidates+=("$root/Package.resolved")
  if [[ ${#candidates[@]} -eq 0 ]]; then
    printf 'no-swift-inputs'
    return 0
  fi
  toolchain_file_hash "${candidates[@]}"
}

# Individual layered keys. Each key contains only the inputs that materially
# affect that layer, so adding Rust never invalidates an unchanged OpenCode
# binary and adding Windows never invalidates macOS caches.
toolchain_key_opencode() {
  local schema=${1:-} os=${2:-} arch=${3:-} version=${4:-}
  printf 'toolchain-opencode-%s-%s-%s-%s' "$schema" "$os" "$arch" "$version"
}

toolchain_key_rust_tools() {
  local schema=${1:-} os=${2:-} arch=${3:-} rust_id=${4:-} cbindgen=${5:-}
  printf 'toolchain-rust-tools-%s-%s-%s-%s-cbindgen-%s' "$schema" "$os" "$arch" "$rust_id" "$cbindgen"
}

toolchain_key_cargo() {
  local schema=${1:-} os=${2:-} arch=${3:-} rust_id=${4:-} lock_hash=${5:-}
  printf 'toolchain-cargo-%s-%s-%s-%s-%s' "$schema" "$os" "$arch" "$rust_id" "$lock_hash"
}

toolchain_key_swiftpm() {
  local schema=${1:-} os=${2:-} arch=${3:-} swift_version=${4:-} graph_hash=${5:-}
  printf 'toolchain-swiftpm-%s-%s-%s-swift-%s-%s' "$schema" "$os" "$arch" "$swift_version" "$graph_hash"
}

# toolchain_rust_id <manifest> [repo-root]
# Stable Rust identity for tool-cache keys: prefer an explicit
# rust-toolchain file hash when Rust exists, else manifest channel+version.
toolchain_rust_id() {
  local manifest=${1:-$TOOLCHAIN_MANIFEST_DEFAULT} root=${2:-.}
  if [[ -f "$root/rust-toolchain.toml" || -f "$root/rust-toolchain" ]]; then
    toolchain_file_hash "$root/rust-toolchain.toml" "$root/rust-toolchain" 2>/dev/null || printf 'no-rust-inputs'
    return 0
  fi
  local channel version
  channel=$(toolchain_manifest_value "$manifest" '.tools.rust.channel' 'stable')
  version=$(toolchain_manifest_value "$manifest" '.tools.rust.version' '')
  if [[ -n "$version" ]]; then
    printf '%s-%s' "$channel" "$version"
  else
    printf '%s' "$channel"
  fi
}

# toolchain_compute_keys [manifest] [repo-root] [os-override] [arch-override]
# Prints KEY=value lines for every layer. Pure: no network, no side effects.
toolchain_compute_keys() {
  local manifest=${1:-$TOOLCHAIN_MANIFEST_DEFAULT} root=${2:-.}
  local os_override=${3:-} arch_override=${4:-}
  local os arch
  read -r os arch < <(toolchain_detect_platform "$os_override" "$arch_override")
  local schema opencode_version swift_version cbindgen rust_id cargo_hash swift_hash
  schema=$(toolchain_manifest_value "$manifest" '.cache_schema' 'v1')
  opencode_version=$(toolchain_manifest_value "$manifest" '.tools.opencode.version' 'unknown')
  swift_version=$(toolchain_manifest_value "$manifest" '.tools.swift.version' 'unknown')
  cbindgen=$(toolchain_manifest_value "$manifest" '.tools.cbindgen.version' 'unknown')
  rust_id=$(toolchain_rust_id "$manifest" "$root")
  cargo_hash=$(toolchain_rust_inputs_hash "$root")
  swift_hash=$(toolchain_swift_inputs_hash "$root")
  printf 'CACHE_SCHEMA=%s\n' "$schema"
  printf 'TOOLCHAIN_OS=%s\n' "$os"
  printf 'TOOLCHAIN_ARCH=%s\n' "$arch"
  printf 'SWIFT_VERSION=%s\n' "$swift_version"
  printf 'OPENCODE_VERSION=%s\n' "$opencode_version"
  printf 'OPENCODE_KEY=%s\n' "$(toolchain_key_opencode "$schema" "$os" "$arch" "$opencode_version")"
  printf 'RUST_ID=%s\n' "$rust_id"
  printf 'RUST_TOOLS_KEY=%s\n' "$(toolchain_key_rust_tools "$schema" "$os" "$arch" "$rust_id" "$cbindgen")"
  printf 'CARGO_KEY=%s\n' "$(toolchain_key_cargo "$schema" "$os" "$arch" "$rust_id" "$cargo_hash")"
  printf 'SWIFTPM_KEY=%s\n' "$(toolchain_key_swiftpm "$schema" "$os" "$arch" "$swift_version" "$swift_hash")"
}

# toolchain_has_rust [repo-root]
# Exit 0 when the Rust engine inputs exist (toolchain file or Cargo manifests).
toolchain_has_rust() {
  local root=${1:-.}
  [[ -f "$root/rust-toolchain.toml" || -f "$root/rust-toolchain" || -f "$root/Cargo.lock" ]] && return 0
  [[ -n "$(find "$root" -maxdepth 2 -name 'Cargo.toml' -not -path '*/target/*' 2>/dev/null | head -n 1)" ]]
}
