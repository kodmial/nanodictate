// Compilation shim for the NanoDictateRustFFI clang target.
//
// The target carries the cbindgen-generated C header
// (include/nanodictate_core.h) as its public interface. This translation
// unit forces the header to compile as C inside the SwiftPM build and
// anchors the module. The Rust static library itself is linked by the
// build script (scripts/build-rust-core.sh) via -L/-lnanodictate_core.

#include "nanodictate_core.h"
