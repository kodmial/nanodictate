/**
 * Unit tests for the pure helper functions in src/commands.ts.
 *
 * Runs on node:test (node >= 22, no extra dependencies) against the compiled
 * dist/commands.js — `npm test` builds first. Only the pure functions are
 * covered; the spawn-based wrappers (run, buildProject, getStatus, ...) are
 * exercised by the real-build verification, not by these tests.
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  matchSigningIdentity,
  parseEntitlements,
  parseTeamId,
  resolveSwiftToolchain,
  tail,
} from "../dist/commands.js";
import { SIGNING_IDENTITY } from "../dist/constants.js";

// ── tail ────────────────────────────────────────────────────────────────────

test("tail keeps the last n non-empty lines", () => {
  assert.equal(tail("a\nb\nc\n", 2), "b\nc");
  assert.equal(tail("a\n\nb\n\n", 1), "b");
  assert.equal(tail("x", 5), "x");
  assert.equal(tail("", 3), "");
  assert.equal(tail("a\nb\nc\nd\ne", 3), "c\nd\ne");
});

// ── parseEntitlements ───────────────────────────────────────────────────────

test("parseEntitlements extracts string, boolean and integer values", () => {
  const xml = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.device.audio-input</key>
  <true/>
  <key>com.example.flag</key>
  <false/>
  <key>com.example.name</key>
  <string>NanoDictate</string>
  <key>com.example.count</key>
  <integer>42</integer>
</dict>
</plist>`;
  assert.deepEqual(parseEntitlements(xml), {
    "com.apple.security.device.audio-input": true,
    "com.example.flag": false,
    "com.example.name": "NanoDictate",
    "com.example.count": 42,
  });
});

test("parseEntitlements returns null for non-dict output", () => {
  assert.equal(parseEntitlements("no plist content"), null);
  assert.equal(parseEntitlements("<dict></dict> — empty"), null);
});

// ── parseTeamId ─────────────────────────────────────────────────────────────

test("parseTeamId normalizes codesign TeamIdentifier values", () => {
  assert.equal(parseTeamId("VTLW9A2S8M"), "VTLW9A2S8M");
  assert.equal(parseTeamId("  ABC123DE45  "), "ABC123DE45");
  assert.equal(parseTeamId("not"), null);
  assert.equal(parseTeamId("not set"), null);
  assert.equal(parseTeamId(null), null);
  assert.equal(parseTeamId(undefined), null);
  assert.equal(parseTeamId(""), null);
});

// ── matchSigningIdentity ────────────────────────────────────────────────────

const sampleOutput = [
  '  1) 0000000000000000000000000000000000000000 "NanoDictate Code Signing"',
  '  2) 1111111111111111111111111111111111111111 "Apple Development: alice@example.com"',
].join("\n");

test("matchSigningIdentity finds the identity in find-identity output", () => {
  assert.deepEqual(
    matchSigningIdentity(sampleOutput, SIGNING_IDENTITY),
    {
      found: true,
      detail: '1) 0000000000000000000000000000000000000000 "NanoDictate Code Signing"',
    },
  );
});

test("matchSigningIdentity lists available identities when not found", () => {
  const res = matchSigningIdentity(
    '  1) 1111 "Other Identity"\n  2) 2222 "Another One"',
    SIGNING_IDENTITY,
  );
  assert.equal(res.found, false);
  assert.match(res.detail, /not found in keychain/);
  assert.match(res.detail, /Other Identity/);
  assert.match(res.detail, /Another One/);
});

test("matchSigningIdentity explains an empty keychain", () => {
  const res = matchSigningIdentity("", SIGNING_IDENTITY);
  assert.equal(res.found, false);
  assert.match(res.detail, /No identities found at all/);
});

// ── resolveSwiftToolchain ───────────────────────────────────────────────────

test("resolveSwiftToolchain uses a valid SWIFT_TOOLCHAIN with manifest env", () => {
  const root = mkdtempSync(join(tmpdir(), "nanodictate-tc-"));
  try {
    mkdirSync(join(root, "usr", "bin"), { recursive: true });
    mkdirSync(join(root, "usr", "lib", "swift", "pm"), { recursive: true });
    writeFileSync(join(root, "usr", "bin", "swift"), "#!/bin/sh\nexit 0\n", {
      mode: 0o755,
    });
    const res = resolveSwiftToolchain({ SWIFT_TOOLCHAIN: root, PATH: "/usr/bin:/bin" });
    assert.equal(res.ok, true);
    assert.deepEqual(res.toolchain, {
      swift: join(root, "usr", "bin", "swift"),
      env: {
        SWIFT_EXEC_MANIFEST: join(root, "usr", "bin", "swiftc"),
        SWIFTPM_CUSTOM_LIBS_DIR: join(root, "usr", "lib", "swift", "pm"),
      },
      source: "SWIFT_TOOLCHAIN",
    });
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("resolveSwiftToolchain errors when SWIFT_TOOLCHAIN has no executable swift", () => {
  const root = mkdtempSync(join(tmpdir(), "nanodictate-tc-"));
  try {
    const res = resolveSwiftToolchain({ SWIFT_TOOLCHAIN: root, PATH: "/usr/bin:/bin" });
    assert.equal(res.ok, false);
    assert.match(res.error, /SWIFT_TOOLCHAIN/);
    assert.match(res.error, new RegExp(join(root, "usr", "bin", "swift")));
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("resolveSwiftToolchain falls back to swift found on PATH", () => {
  const bin = mkdtempSync(join(tmpdir(), "nanodictate-bin-"));
  try {
    writeFileSync(join(bin, "swift"), "#!/bin/sh\nexit 0\n", { mode: 0o755 });
    const res = resolveSwiftToolchain({ PATH: `${bin}:/usr/bin` });
    assert.equal(res.ok, true);
    assert.equal(res.toolchain.swift, join(bin, "swift"));
    assert.equal(res.toolchain.source, "PATH");
    assert.deepEqual(res.toolchain.env, {});
  } finally {
    rmSync(bin, { recursive: true, force: true });
  }
});

test("resolveSwiftToolchain errors when no swift is available anywhere", () => {
  const res = resolveSwiftToolchain({ PATH: "/nonexistent-dir" });
  assert.equal(res.ok, false);
  assert.match(res.error, /not found in PATH/);
  assert.match(res.error, /SWIFT_TOOLCHAIN/);
});