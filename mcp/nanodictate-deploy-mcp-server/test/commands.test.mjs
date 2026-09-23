/**
 * Unit tests for the pure helper functions in src/commands.ts.
 *
 * Runs on node:test (node >= 22, no extra dependencies) against the compiled
 * dist/commands.js — `npm test` builds first. Only the pure functions are
 * covered; the spawn-based wrappers (run, buildProject, getStatus, ...) are
 * exercised by the real-build verification, not by these tests.
 */

import { after, test } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, join } from "node:path";
import {
  matchSigningIdentity,
  parseEntitlements,
  parseTeamId,
  resolveSwiftToolchain,
  signBundle,
  signOneBinary,
  signProject,
  tail,
  TCC_GRANTS_CHECK_LABEL,
  TCC_GRANTS_LABEL,
  TCC_RECORDS_STEP_ID,
} from "../dist/commands.js";
import {
  NANODICTATE_BUNDLE_ID,
  APP_BUNDLE_NAME,
  SIGNING_IDENTITY,
  TCC_GRANTS_DELETE_CMD,
  TCC_GRANTS_SELECT_CMD,
  binaryPaths,
} from "../dist/constants.js";

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
// ── dictation_wipe + dictation_cert_* (mocked deps, no real system calls) ──

import {
  ensureCiSigningIdentity,
  findNanodictatePaths,
  getCertStatus,
  listCodeSigningIdentities,
  matchBrewList,
  matchPortInstalled,
  parseFindIdentity,
  parsePgrep,
  publishCiSigningToGithub,
  resolveTapCloneDir,
  wipeProject,
} from "../dist/commands.js";
import {
  ACCESSIBILITY_STAMP_KEY,
  AGENT_BUNDLE_ID,
  CI_P12_PASSWORD_SECRET,
  CI_P12_SECRET,
  CI_SIGNING_IDENTITY,
  MACPORTS_PORT_BIN,
  NANODICTATE_TAP,
  NANODICTATE_TAP_CLONE_DIR,
  PROJECT_ROOT,
  tapCloneDir,
  wipePaths,
} from "../dist/constants.js";

// Unique per-run HOME (mkdtemp) so the wipe/cert fakes never collide with a
// fixed "/tmp/nanodictate-test-home" left behind by an earlier run; removed
// after the whole file's tests complete.
const HOME = mkdtempSync(join(tmpdir(), "nanodictate-test-home-"));
after(() => rmSync(HOME, { recursive: true, force: true }));
const P = wipePaths(HOME);
const TCC_CMD = TCC_GRANTS_DELETE_CMD;
// the TCC block now carries BOTH a read-only check (SELECT) and the erase
// (DELETE), each behind its own label, so the user can inspect before cleaning.
const TCC_MANUAL = [
  TCC_GRANTS_CHECK_LABEL,
  TCC_GRANTS_SELECT_CMD,
  TCC_GRANTS_LABEL,
  TCC_GRANTS_DELETE_CMD,
];

/**
 * Scripted fake deps: every spawn is answered in-process, nothing real runs.
 */
function makeFakeDeps(opts = {}) {
  const calls = [];
  const state = {
    brewListed: false,
    tapClone: false,
    cacheFiles: [],
    portBin: false,
    portInstalled: false,
    launchLoaded: false,
    files: new Set(),
    stampSet: false,
    pids: [],
    dieBetweenPgrep: false,
    defaultsDeleteAbsent: false,
    identities: [],
    findIdentityBlank: false,
    importFail: false,
    partitionFail: false,
    python3Fail: false,
    exportFail: false,
    exportNoWrite: false,
    untapKeepsClone: false,
    verifyStdout: "CN=" + CI_SIGNING_IDENTITY,
    ghStatus: 1,
    ghStdout: "",
    ghSetFail: false,
    /** brew --repository output; null simulates brew being absent. */
    brewRepository: "/opt/homebrew",
    ...(opts.state ?? {}),
  };
  const mkres = (status, stdout, stderr) => ({ status, stdout, stderr });
  const ok = (stdout = "", stderr = "") => mkres(0, stdout, stderr);
  const fail = (stderr = "") => mkres(1, "", stderr);
  // The tap clone path wipeProject probes follows the runtime resolution:
  // `$(brew --repository)/Library/Taps/…` when brew answers, arch fallback when absent.
  const tapPath = () =>
    state.brewRepository == null
      ? NANODICTATE_TAP_CLONE_DIR
      : tapCloneDir(state.brewRepository);

  const runFn = async (cmd, args = [], ropts) => {
    calls.push({ cmd, args, opts: ropts });
    if (cmd === "brew" && args[0] === "list") {
      return state.brewListed ? ok("nanodictate 0.0.12\n") : fail("Error: No such keg");
    }
    if (cmd === "brew" && args[0] === "--repository") {
      return state.brewRepository == null
        ? fail("brew: command not found")
        : ok(state.brewRepository + "\n");
    }
    if (cmd === "brew" && args[0] === "uninstall") {
      state.brewListed = false;
      return ok("Uninstalling nanodictate\n");
    }
    if (cmd === "brew" && args[0] === "untap") {
      if (!state.untapKeepsClone) state.tapClone = false;
      return ok();
    }
    if (cmd === "/usr/bin/find") return ok(state.cacheFiles.join("\n"));
    if (cmd === "/bin/ls") {
      // Honest `ls -A <dir>`: return the bare names inside the directory —
      // no glob simulation, so a literal `*` argument would find nothing.
      const idx = args.indexOf("-A");
      const dir = idx >= 0 ? args[idx + 1] : args[args.length - 1];
      const names = [...state.files]
        .map((p) => ({ dir: dirname(p), name: basename(p) }))
        .filter((e) => e.dir === dir)
        .map((e) => e.name);
      return ok(names.join("\n"));
    }
    if (cmd === "/bin/rm") {
      for (const p of args.slice(1)) {
        state.files.delete(p);
        state.cacheFiles = state.cacheFiles.filter((f) => f !== p);
        if (p === tapPath()) state.tapClone = false;
      }
      return ok();
    }
    if (cmd === "defaults" && args[0] === "read") {
      return state.stampSet ? ok("1750000000\n") : fail("The domain/default pair does not exist");
    }
    if (cmd === "defaults" && args[0] === "delete") {
      const was = state.stampSet;
      state.stampSet = false;
      return was && !state.defaultsDeleteAbsent ? ok() : fail("The domain/default pair does not exist");
    }
    if (cmd === "/bin/launchctl" && args[0] === "print") {
      return state.launchLoaded ? ok("service = com.nanodictate.agent\n") : fail("Could not find service");
    }
    if (cmd === "/bin/launchctl" && args[0] === "bootout") {
      state.launchLoaded = false;
      return ok();
    }
    if (cmd === "sudo" && args.includes("installed")) {
      return state.portInstalled
        ? ok("nanodictate @0.0.12_0 (active)\n")
        : ok("None of the specified ports are installed.\n");
    }
    if (cmd === "sudo" && args.includes("uninstall")) {
      state.portInstalled = false;
      return ok();
    }
    if (cmd === "sudo" && args.includes("clean")) return ok();
    if (cmd === "/usr/bin/pgrep") {
      state.pgrepCalls = (state.pgrepCalls ?? 0) + 1;
      if (state.pids.length === 0) return fail();
      if (state.dieBetweenPgrep && state.pgrepCalls > 1) return fail();
      return ok(state.pids.join("\n") + "\n");
    }
    if (cmd === "/usr/bin/pkill") {
      state.pids = [];
      return ok();
    }
    if (cmd === "/usr/bin/python3") {
      return state.python3Fail ? fail("ModuleNotFoundError: no module named 'cryptography'") : ok(state.verifyStdout);
    }
    if (cmd === "security" && args[0] === "find-identity") {
      const lines = state.findIdentityBlank
        ? ""
        : state.identities.map((n, i) => `${i + 1}) ${"AB".repeat(20)} "${n}"`).join("\n");
      return ok(lines);
    }
    if (cmd === "security" && args[0] === "import") {
      if (state.importFail) return fail("security: SecKeychainItemImport failed (errSecInternalComponent)");
      state.identities.push(CI_SIGNING_IDENTITY);
      return ok();
    }
    if (cmd === "security" && args[0] === "set-key-partition-list") {
      return state.partitionFail ? fail("Unable to access keychain") : ok();
    }
    if (cmd === "security" && args[0] === "export") {
      if (state.exportFail) return fail("security: couldn't find item on keychain");
      const idx = args.indexOf("-o");
      if (idx >= 0 && !state.exportNoWrite) writeFileSync(args[idx + 1], Buffer.from("fake-p12-bytes"));
      return ok("1 identity exported");
    }
    if (cmd === "gh" && args[0] === "secret" && args[1] === "list") {
      return state.ghStatus === 0 ? ok(state.ghStdout) : fail("HTTP 403: API rate limit exceeded (try again in a minute)");
    }
    if (cmd === "gh" && args[0] === "secret" && args[1] === "set") {
      return state.ghSetFail ? fail("failed to set secret") : ok();
    }
    throw new Error(`unhandled fake command: ${cmd} ${args.join(" ")}`);
  };

  const existsFn = (p) => {
    if (p === tapPath()) return state.tapClone;
    if (p === MACPORTS_PORT_BIN) return state.portBin;
    return state.files.has(p);
  };

  return {
    calls,
    state,
    tapPath,
    deps: { runFn, existsFn, home: HOME, uid: "503" },
  };
}

const DESTRUCTIVE = (c) =>
  c.cmd === "/bin/rm" ||
  c.cmd === "/usr/bin/pkill" ||
  (c.cmd === "/bin/launchctl" && c.args[0] === "bootout") ||
  (c.cmd === "defaults" && c.args[0] === "delete") ||
  (c.cmd === "brew" && (c.args[0] === "uninstall" || c.args[0] === "untap")) ||
  (c.cmd === "sudo" && (c.args.includes("uninstall") || c.args.includes("clean"))) ||
  c.cmd === "gh";

// -- parsers ---------------------------------------------------------------

test("matchBrewList recognizes the nanodictate formula line", () => {
  assert.equal(matchBrewList("nanodictate 0.0.12\nother 2.0\n"), true);
  assert.equal(matchBrewList(""), false);
  assert.equal(matchBrewList("Error: No such keg\n"), false);
  assert.equal(matchBrewList("nanodictate\n"), false); // empty version column
});

test("matchPortInstalled matches the port line, not the none-installed notice", () => {
  assert.equal(matchPortInstalled("nanodictate @0.0.12_0 (active)\n"), true);
  assert.equal(matchPortInstalled("None of the specified ports are installed.\n"), false);
  assert.equal(matchPortInstalled(""), false);
});

test("parsePgrep extracts PIDs from pgrep stdout", () => {
  assert.deepEqual(parsePgrep("4242\n4243\n"), [4242, 4243]);
  assert.deepEqual(parsePgrep("  9 12 "), [9, 12]);
  assert.deepEqual(parsePgrep(""), []);
  assert.deepEqual(parsePgrep("garbage"), []);
});

test("findNanodictatePaths keeps only nanodictate lines", () => {
  assert.deepEqual(
    findNanodictatePaths("/x/cache/nanodictate-0.0.12.tar.gz\n/y/NanoDictateAgent.dmg\n/z/other\n"),
    ["/x/cache/nanodictate-0.0.12.tar.gz", "/y/NanoDictateAgent.dmg"],
  );
  assert.deepEqual(findNanodictatePaths(""), []);
});

test("parseFindIdentity parses security find-identity lines", () => {
  const out = parseFindIdentity(' 1) ABCDEF0123456789ABCDEF0123456789ABCDEF01 "NanoDictate CI Signing"\n 2) "no sha"\n');
  assert.deepEqual(out, [
    { sha1: "ABCDEF0123456789ABCDEF0123456789ABCDEF01", name: "NanoDictate CI Signing" },
  ]);
});

// -- dictation_wipe ---------------------------------------------------------

test("wipeProject dry run probes everything but deletes nothing", async () => {
  const fake = makeFakeDeps({
    state: {
      brewListed: true,
      tapClone: true,
      cacheFiles: [`${HOME}/Library/Caches/Homebrew/downloads/nanodictate-0.0.12.tar.gz`],
      portBin: true,
      portInstalled: true,
      launchLoaded: true,
      files: new Set([
        P.userPlist,
        P.configDir,
        P.userLogsDir,
        P.rootPlist,
        P.rootLogsDir,
        P.symlink,
        P.downloadsCache,
        `${HOME}/.nanodictate-extra`,
      ]),
      stampSet: true,
      pids: [4242],
    },
  });
  const res = await wipeProject({ dryRun: true, deps: fake.deps });
  assert.equal(res.dryRun, true);
  assert.equal(res.success, false);
  assert.equal(res.newcomerReady, false);
  assert.equal(fake.calls.filter(DESTRUCTIVE).length, 0, "no destructive command in dry run");
  assert.equal(res.items.some((i) => i.status === "wiped"), false);
  assert.equal(res.items.some((i) => i.status === "dryrun"), true);
  const byId = Object.fromEntries(res.items.map((i) => [i.id, i]));
  assert.equal(byId.brewFormula.status, "dryrun");
  assert.equal(byId.brewTapClone.status, "dryrun");
  assert.equal(byId.macportsPort.status, "dryrun");
  assert.equal(byId.launchAgentLoaded.status, "dryrun");
  assert.equal(byId.rootPlist.status, "manual-sudo");
  assert.equal(byId.rootLogs.status, "manual-sudo");
  assert.equal(byId.agentProcesses.status, "dryrun");
  assert.deepEqual(res.manualCommands, [
    `sudo rm -f ${P.rootPlist}`,
    `sudo rm -rf ${P.rootLogsDir}`,
    ...TCC_MANUAL,
  ]);
  assert.deepEqual(res.leftover, ["rootPlist", "rootLogs"]);
  assert.deepEqual(res.pidsAfter, [4242]);
});

test("wipeProject on a clean machine succeeds without deleting anything", async () => {
  const fake = makeFakeDeps(); // everything absent
  const res = await wipeProject({ dryRun: false, deps: fake.deps });
  assert.equal(res.success, true);
  assert.equal(res.newcomerReady, true);
  const tcc = res.items.find((i) => i.id === TCC_RECORDS_STEP_ID);
  assert.equal(tcc.status, "manual-sudo");
  assert.equal(res.items.filter((i) => i.id !== TCC_RECORDS_STEP_ID).every((i) => i.status === "clean"), true);
  assert.deepEqual(res.manualCommands, TCC_MANUAL);
  assert.equal(res.leftover.length, 0);
  assert.equal(fake.calls.filter(DESTRUCTIVE).length, 0);
  assert.deepEqual(res.pidsAfter, []);
});

test("wipeProject real run deletes probed items and skips root-owned ones", async () => {
  const fake = makeFakeDeps({
    state: {
      brewListed: true,
      tapClone: true,
      cacheFiles: [`${P.downloadsCache}/nanodictate--0.0.12.arm64_sonoma.bottle.tar.gz`],
      portBin: true,
      portInstalled: true,
      launchLoaded: true,
      files: new Set([
        P.userPlist,
        P.configDir,
        P.userLogsDir,
        P.rootPlist,
        P.rootLogsDir,
        P.symlink,
        P.downloadsCache,
        `${HOME}/.nanodictate-history.json`,
        `${HOME}/.zshrc`,
      ]),
      stampSet: true,
      pids: [4242],
    },
  });
  const res = await wipeProject({ dryRun: false, deps: fake.deps });
  const byId = Object.fromEntries(res.items.map((i) => [i.id, i]));
  assert.equal(byId.brewFormula.status, "wiped");
  assert.equal(byId.brewTapClone.status, "wiped");
  assert.equal(byId.brewCaches.status, "wiped");
  assert.equal(byId.macportsPort.status, "wiped");
  assert.equal(byId.launchAgentLoaded.status, "wiped");
  assert.equal(byId.userPlist.status, "wiped");
  assert.equal(byId.configDir.status, "wiped");
  assert.equal(byId.userLogs.status, "wiped");
  assert.equal(byId.symlink.status, "wiped");
  assert.equal(byId.homeDotfiles.status, "wiped");
  assert.equal(byId.accessibilityStamp.status, "wiped");
  assert.equal(byId.agentProcesses.status, "wiped");
  assert.equal(byId.rootPlist.status, "manual-sudo");
  assert.equal(byId.rootLogs.status, "manual-sudo");
  assert.equal(res.success, false, "root items remain → not newcomer-ready");
  assert.deepEqual(res.leftover, ["rootPlist", "rootLogs"]);
  assert.deepEqual(res.pidsAfter, []);
  // destructive commands that did run
  const keys = new Set(fake.calls.map((c) => `${c.cmd} ${c.args.join(" ")}`));
  assert.ok(keys.has("brew uninstall --force nanodictate"));
  assert.ok(keys.has("/bin/launchctl bootout gui/503/com.nanodictate.agent"));
  assert.ok(keys.has("defaults delete com.nanodictate.agent NanoDictate.lastAccessibilityPanelOpenAt"));
  assert.ok(keys.has("/usr/bin/pkill -f NanoDictateAgent"));
  assert.ok(keys.has("sudo -n /opt/local/bin/port uninstall nanodictate"));
  // root-owned plist was never passed to rm
  assert.equal(fake.calls.some((c) => c.cmd === "/bin/rm" && c.args.includes(P.rootPlist)), false);
  assert.equal(fake.calls.some((c) => c.cmd === "/bin/rm" && c.args.includes(P.rootLogsDir)), false);
  // homeDotfiles finds the `.nanodictate`-prefixed file via `ls -A` + in-process
  // filter and removes it; the unrelated `.zshrc` never reaches rm.
  assert.equal(fake.state.files.has(`${HOME}/.nanodictate-history.json`), false, "prefixed dotfile removed");
  assert.equal(
    fake.calls.some((c) => c.cmd === "/bin/rm" && c.args.includes(join(HOME, ".zshrc"))),
    false,
    "unrelated home files survive the wipe",
  );
});

test("wipeProject without root leftovers on a dirty machine is newcomer-ready", async () => {
  const fake = makeFakeDeps({
    state: {
      brewListed: true,
      launchLoaded: true,
      files: new Set([P.userPlist, P.configDir, P.userLogsDir, P.symlink]),
      stampSet: true,
    },
  });
  const res = await wipeProject({ dryRun: false, deps: fake.deps });
  assert.equal(res.success, true);
  assert.equal(res.newcomerReady, true);
  assert.deepEqual(res.manualCommands, TCC_MANUAL);
  const byId = Object.fromEntries(res.items.map((i) => [i.id, i]));
  assert.equal(byId.rootPlist.status, "clean");
  assert.equal(byId.rootLogs.status, "clean");
});

test("wipeProject tolerates the cooldown stamp vanishing mid-run", async () => {
  const fake = makeFakeDeps({
    state: { stampSet: true, defaultsDeleteAbsent: true },
  });
  const res = await wipeProject({ dryRun: false, deps: fake.deps });
  const stamp = res.items.find((i) => i.id === "accessibilityStamp");
  assert.equal(stamp.status, "wiped");
  assert.match(stamp.detail, /already absent — ok/);
});

test("wipeProject skips pkill when the process died between probe and kill", async () => {
  const fake = makeFakeDeps({
    state: { pids: [4242], dieBetweenPgrep: true },
  });
  const res = await wipeProject({ dryRun: false, deps: fake.deps });
  const procs = res.items.find((i) => i.id === "agentProcesses");
  assert.equal(procs.status, "wiped");
  assert.equal(fake.calls.some((c) => c.cmd === "/usr/bin/pkill"), false);
});

test("wipeProject skips MacPorts when /opt/local/bin/port is absent", async () => {
  const fake = makeFakeDeps({ state: { portInstalled: true } }); // portBin false, port "set" irrelevant
  const res = await wipeProject({ dryRun: false, deps: fake.deps });
  const port = res.items.find((i) => i.id === "macportsPort");
  assert.equal(port.status, "clean");
  assert.match(port.detail, /macports not installed/);
});

// ── TCC records step ────────────────────────────────────────────────────────

test("wipeProject TCC step is always manual-sudo and never executed (dry run)", async () => {
  const fake = makeFakeDeps(); // everything absent
  const res = await wipeProject({ dryRun: true, deps: fake.deps });
  const tcc = res.items.find((i) => i.id === TCC_RECORDS_STEP_ID);
  assert.ok(tcc, "tccRecords step present in items");
  assert.equal(tcc.status, "manual-sudo");
  assert.match(tcc.detail, /cannot read TCC\.db/);
  assert.match(tcc.detail, /Full Disk Access/, "detail states the system db needs FDA");
  assert.equal(tcc.command, TCC_CMD);
  // the wipe never touches the system TCC.db — no sqlite3 spawn at all
  assert.equal(
    fake.calls.some((c) => c.args.some((a) => a.includes("com.apple.TCC"))),
    false,
  );
  assert.deepEqual(res.manualCommands, TCC_MANUAL);
  // the TCC block emits BOTH commands — read-only check first, erase second —
  // each under its own label; the check label carries the duplicate hint.
  const tccIdx = res.manualCommands.indexOf(TCC_GRANTS_CHECK_LABEL);
  const delIdx = res.manualCommands.indexOf(TCC_GRANTS_LABEL);
  assert.ok(tccIdx >= 0, "check label present");
  assert.ok(delIdx > tccIdx, "check label precedes the erase label");
  assert.ok(TCC_GRANTS_SELECT_CMD.startsWith("UDIR="), "SELECT uses the UDIR prefix");
  assert.match(TCC_GRANTS_CHECK_LABEL, /c>1 = дубли/);
  assert.ok(res.manualCommands.includes(TCC_GRANTS_SELECT_CMD), "SELECT command present");
  assert.ok(res.manualCommands.includes(TCC_GRANTS_DELETE_CMD), "DELETE command present");
});

test("wipeProject TCC step stays manual in a real run with the same command, nothing executed", async () => {
  const fake = makeFakeDeps({ state: { brewListed: true } }); // dirty machine, real run
  const res = await wipeProject({ dryRun: false, deps: fake.deps });
  const tcc = res.items.find((i) => i.id === TCC_RECORDS_STEP_ID);
  assert.equal(tcc.status, "manual-sudo");
  assert.equal(tcc.command, TCC_CMD);
  assert.deepEqual(res.manualCommands, TCC_MANUAL);
  assert.equal(
    fake.calls.some((c) => c.args.some((a) => a.includes("com.apple.TCC"))),
    false,
  );
  // positioned between the accessibility stamp and the agent processes
  const order = res.items.map((i) => i.id);
  assert.ok(order.indexOf("accessibilityStamp") < order.indexOf(TCC_RECORDS_STEP_ID));
  assert.ok(order.indexOf(TCC_RECORDS_STEP_ID) < order.indexOf("agentProcesses"));
});

test("wipeProject TCC step never blocks newcomer readiness", async () => {
  const fake = makeFakeDeps(); // everything absent
  const res = await wipeProject({ dryRun: false, deps: fake.deps });
  assert.equal(res.newcomerReady, true);
  const tcc = res.items.find((i) => i.id === TCC_RECORDS_STEP_ID);
  assert.equal(tcc.status, "manual-sudo");
  assert.equal(tcc.status === "clean" || tcc.status === "wiped", false);
  assert.equal(res.leftover.includes(TCC_RECORDS_STEP_ID), false);
  // the TCC manual-erasure phrase always appears in the output detail
  assert.match(res.detail, /TCC Accessibility\/Microphone grants are erased manually/);
});

// -- tap clone dir resolution (brew --repository) -----------------------------

test("resolveTapCloneDir takes the path from brew --repository output", async () => {
  const res = await resolveTapCloneDir(
    async () => ({ status: 0, stdout: "/opt/homebrew\n", stderr: "" }),
    "arm64",
  );
  assert.equal(res.path, "/opt/homebrew/Library/Taps/kodmial/homebrew-nanodictate");
  assert.equal(res.source, "brew");
  assert.equal(res.path.includes("/Homebrew"), false);
});

test("resolveTapCloneDir falls back to the ARM layout (no /Homebrew) when brew is absent", async () => {
  const res = await resolveTapCloneDir(
    async () => ({ status: -1, stdout: "", stderr: "ENOENT" }),
    "arm64",
  );
  assert.equal(res.path, "/opt/homebrew/Library/Taps/kodmial/homebrew-nanodictate");
  assert.equal(res.source, "arch-fallback");
  assert.equal(res.path.includes("/Homebrew"), false);
});

test("resolveTapCloneDir falls back to the Intel layout (with /Homebrew) when brew is absent", async () => {
  const res = await resolveTapCloneDir(
    async () => ({ status: 1, stdout: "", stderr: "brew: command not found" }),
    "x64",
  );
  assert.equal(res.path, "/usr/local/Homebrew/Library/Taps/kodmial/homebrew-nanodictate");
  assert.equal(res.source, "arch-fallback");
  assert.equal(res.path.includes("/Homebrew/Library/Taps"), true);
});

// -- dictation_cert_status ---------------------------------------------------

test("listCodeSigningIdentities returns [] on probe failure", async () => {
  const fake = makeFakeDeps({ state: { ghStatus: 0 } });
  fake.calls.length = 0;
  // no handler override: route security find-identity to failure by blanking identities
  const ids = await listCodeSigningIdentities(fake.deps);
  assert.deepEqual(ids, []);
});

test("getCertStatus reports local identities and GitHub secrets", async () => {
  const fake = makeFakeDeps({
    state: {
      identities: [CI_SIGNING_IDENTITY, SIGNING_IDENTITY],
      ghStatus: 0,
      ghStdout: `NANODICTATE_SIGNING_P12\tUpdate\n${CI_P12_PASSWORD_SECRET}\tUpdate\nNODE_ENV\tUpdate\n`,
    },
  });
  const res = await getCertStatus(fake.deps);
  assert.equal(res.success, true);
  assert.equal(res.ciSigningPresent, true);
  assert.equal(res.devIdentityPresent, true);
  assert.equal(res.usableLocal, true);
  assert.equal(res.githubSecrets.status, "present");
});

test("getCertStatus never throws when GitHub is unreachable", async () => {
  const fake = makeFakeDeps({ state: { identities: [SIGNING_IDENTITY], ghStatus: 1 } });
  const res = await getCertStatus(fake.deps);
  assert.equal(res.ciSigningPresent, false);
  assert.equal(res.githubSecrets.status, "unreachable");
  assert.equal(res.githubSecrets.detail.length > 0, true);
});

// -- dictation_cert_ensure ---------------------------------------------------

test("ensureCiSigningIdentity is a no-op when the identity already exists", async () => {
  const fake = makeFakeDeps({ state: { identities: [CI_SIGNING_IDENTITY] } });
  const res = await ensureCiSigningIdentity(fake.deps);
  assert.equal(res.action, "exists");
  assert.equal(res.success, true);
  assert.equal(fake.calls.filter((c) => c.cmd === "/usr/bin/python3").length, 0);
  assert.equal(fake.calls.some((c) => c.cmd === "security" && c.args[0] === "import"), false);
});

test("ensureCiSigningIdentity creates + imports when absent", async () => {
  const fake = makeFakeDeps();
  const res = await ensureCiSigningIdentity(fake.deps);
  assert.equal(res.action, "created");
  assert.equal(res.success, true);
  assert.equal(res.ciSigningPresent, true);
  assert.equal(res.warnings.length, 0);
  assert.equal(fake.calls.filter((c) => c.cmd === "/usr/bin/python3").length, 1);
  const importCall = fake.calls.find((c) => c.cmd === "security" && c.args[0] === "import");
  assert.ok(importCall, "security import ran");
  assert.ok(importCall.args.includes("-T"));
  assert.ok(importCall.args.includes("/usr/bin/codesign"));
  const partitionCall = fake.calls.find((c) => c.cmd === "security" && c.args[0] === "set-key-partition-list");
  assert.ok(partitionCall, "set-key-partition-list ran");
  // label filter keeps the partition-list update scoped to the CI identity
  const labelIdx = partitionCall.args.indexOf("-l");
  assert.ok(labelIdx >= 0, "partition-list call is labeled with -l");
  assert.equal(partitionCall.args[labelIdx + 1], CI_SIGNING_IDENTITY, "label selects the CI identity");
});

test("ensureCiSigningIdentity reports generator failure", async () => {
  const fake = makeFakeDeps({ state: { python3Fail: true } });
  const res = await ensureCiSigningIdentity(fake.deps);
  assert.equal(res.action, "error");
  assert.equal(res.success, false);
  assert.match(res.detail, /generation failed/);
  assert.equal(fake.calls.some((c) => c.cmd === "security" && c.args[0] === "import"), false);
});

test("ensureCiSigningIdentity reports import failure", async () => {
  const fake = makeFakeDeps({ state: { importFail: true } });
  const res = await ensureCiSigningIdentity(fake.deps);
  assert.equal(res.action, "error");
  assert.equal(res.success, false);
  assert.match(res.detail, /import failed/);
});

test("ensureCiSigningIdentity reports when import lied (identity not visible)", async () => {
  const fake = makeFakeDeps({ state: { findIdentityBlank: true } });
  const res = await ensureCiSigningIdentity(fake.deps);
  assert.equal(res.action, "error");
  assert.match(res.detail, /not visible/);
});

test("ensureCiSigningIdentity downgrades partition-list failure to a warning", async () => {
  const fake = makeFakeDeps({ state: { partitionFail: true } });
  const res = await ensureCiSigningIdentity(fake.deps);
  assert.equal(res.action, "created");
  assert.equal(res.warnings.length, 1);
  assert.match(res.warnings[0], /set-key-partition-list/);
});

// -- dictation_cert_publish_github -------------------------------------------

test("publish refuses when there is no local CI identity", async () => {
  const fake = makeFakeDeps();
  const res = await publishCiSigningToGithub({ execute: true, deps: fake.deps });
  assert.equal(res.success, false);
  assert.equal(res.executed, false);
  assert.equal(res.localCertPresent, false);
  assert.equal(res.p12Base64, null);
  assert.match(res.instructions[0], /dictation_cert_ensure/);
  assert.equal(fake.calls.some((c) => c.cmd === "gh"), false);
});

test("publish refuses to overwrite existing secrets", async () => {
  const fake = makeFakeDeps({
    state: {
      identities: [CI_SIGNING_IDENTITY],
      ghStatus: 0,
      ghStdout: `${CI_P12_SECRET}\n${CI_P12_PASSWORD_SECRET}\n`,
    },
  });
  const res = await publishCiSigningToGithub({ execute: true, deps: fake.deps });
  assert.equal(res.success, false);
  assert.equal(res.executed, false);
  assert.equal(res.secretsState, "present");
  assert.match(res.detail, /refusing to overwrite/);
  assert.equal(fake.calls.some((c) => c.cmd === "security" && c.args[0] === "export"), false);
  assert.equal(fake.calls.some((c) => c.cmd === "gh" && c.args[1] === "set"), false);
});

test("publish prepares p12 but writes nothing when GitHub is unreachable", async () => {
  const fake = makeFakeDeps({ state: { identities: [CI_SIGNING_IDENTITY], ghStatus: 1 } });
  const res = await publishCiSigningToGithub({ execute: true, deps: fake.deps });
  assert.equal(res.success, false);
  assert.equal(res.executed, false);
  assert.equal(res.secretsState, "unreachable");
  assert.ok(res.p12Base64, "p12 material still prepared");
  assert.ok(res.password);
  assert.ok(res.instructions.some((l) => l.includes("gh secret list is unreachable")));
  assert.equal(fake.calls.some((c) => c.cmd === "gh" && c.args[1] === "set"), false);
});

test("publish with execute=false only prepares instructions", async () => {
  const fake = makeFakeDeps({ state: { identities: [CI_SIGNING_IDENTITY], ghStatus: 0, ghStdout: "" } });
  const res = await publishCiSigningToGithub({ execute: false, deps: fake.deps });
  assert.equal(res.success, true);
  assert.equal(res.executed, false);
  assert.equal(res.secretsState, "absent");
  assert.ok(res.p12Base64);
  assert.ok(res.instructions.some((l) => l.includes(`gh secret set ${CI_P12_SECRET}`)));
  assert.ok(res.instructions.some((l) => l.includes(`gh secret set ${CI_P12_PASSWORD_SECRET}`)));
  assert.equal(fake.calls.some((c) => c.cmd === "gh" && c.args[1] === "set"), false);
});

test("publish with execute=true runs gh secret set only when absence is confirmed", async () => {
  const fake = makeFakeDeps({ state: { identities: [CI_SIGNING_IDENTITY], ghStatus: 0, ghStdout: "" } });
  const res = await publishCiSigningToGithub({ execute: true, deps: fake.deps });
  assert.equal(res.success, true);
  assert.equal(res.executed, true);
  // After a successful install the secrets are owned by GitHub — they must not
  // be echoed back into the result.
  assert.equal(res.p12Base64, null);
  assert.equal(res.password, null);
  const sets = fake.calls.filter((c) => c.cmd === "gh" && c.args[1] === "set");
  assert.equal(sets.length, 2);
  assert.equal(sets[0].args[2], CI_P12_SECRET);
  assert.equal(sets[1].args[2], CI_P12_PASSWORD_SECRET);
  // the values travel via stdin (RunOptions.input), never in argv — a --body
  // argument would leak the secret into `ps` output and logs.
  for (const set of sets) {
    assert.equal(set.args.includes("--body"), false, "secret value must not appear in argv");
    assert.equal(typeof set.opts?.input, "string", "secret value must be piped via stdin");
    assert.equal(set.opts?.cwd, PROJECT_ROOT, "gh must run from the repo root");
  }
  // absence probe must also run from the repo root, not the caller's cwd
  const list = fake.calls.find((c) => c.cmd === "gh" && c.args[1] === "list");
  assert.equal(list?.opts?.cwd, PROJECT_ROOT);
});

test("publish reports gh secret set failure of one secret", async () => {
  const fake = makeFakeDeps({
    state: { identities: [CI_SIGNING_IDENTITY], ghStatus: 0, ghStdout: "", ghSetFail: true },
  });
  const res = await publishCiSigningToGithub({ execute: true, deps: fake.deps });
  assert.equal(res.success, false);
  assert.equal(res.executed, true);
  assert.match(res.detail, /gh secret set failed/);
});

test("publish refuses a p12 that contains a foreign certificate", async () => {
  const fake = makeFakeDeps({
    state: {
      identities: [CI_SIGNING_IDENTITY],
      ghStatus: 0,
      ghStdout: "",
      verifyStdout: `CN=Some Other Identity|CN=${CI_SIGNING_IDENTITY}`,
    },
  });
  const res = await publishCiSigningToGithub({ execute: true, deps: fake.deps });
  assert.equal(res.success, false);
  assert.equal(res.executed, false);
  assert.match(res.detail, /refusing to publish/);
});

test("publish reports export failure without touching GitHub", async () => {
  const fake = makeFakeDeps({
    state: { identities: [CI_SIGNING_IDENTITY], ghStatus: 0, ghStdout: "", exportFail: true },
  });
  const res = await publishCiSigningToGithub({ execute: true, deps: fake.deps });
  assert.equal(res.success, false);
  assert.match(res.detail, /export failed/);
  assert.equal(fake.calls.some((c) => c.cmd === "gh" && c.args[1] === "set"), false);
});

test("probeGithubSecrets treats partial configuration as absent", async () => {
  const fake = makeFakeDeps({
    state: { identities: [CI_SIGNING_IDENTITY], ghStatus: 0, ghStdout: `${CI_P12_SECRET}\n` },
  });
  const res = await publishCiSigningToGithub({ execute: false, deps: fake.deps });
  assert.equal(res.secretsState, "absent");
  assert.match(res.instructions.join("\n"), /partial configuration/);
});

// ── review follow-ups: fallback / refusal branches ──────────────────────────

test("wipeProject falls back to rm -rf when brew untap leaves the tap clone", async () => {
  const fake = makeFakeDeps({
    state: { tapClone: true, untapKeepsClone: true },
  });
  const res = await wipeProject({ dryRun: false, deps: fake.deps });
  const tap = res.items.find((i) => i.id === "brewTapClone");
  assert.equal(tap.status, "wiped");
  const keys = new Set(fake.calls.map((c) => `${c.cmd} ${c.args.join(" ")}`));
  assert.ok(keys.has(`brew untap ${NANODICTATE_TAP}`));
  assert.ok(
    keys.has(`/bin/rm -rf ${fake.tapPath()}`),
    "rm -rf fallback ran on the runtime-resolved tap clone after a no-op untap",
  );
  assert.equal(res.success, true);
  assert.equal(res.newcomerReady, true);
});

test("publish refuses when the p12 verification script fails", async () => {
  const fake = makeFakeDeps({
    state: {
      identities: [CI_SIGNING_IDENTITY],
      ghStatus: 0,
      ghStdout: "",
      python3Fail: true,
    },
  });
  const res = await publishCiSigningToGithub({ execute: true, deps: fake.deps });
  assert.equal(res.success, false);
  assert.equal(res.executed, false);
  assert.equal(res.p12Base64, null);
  assert.match(res.detail, /p12 verification failed/);
  assert.equal(fake.calls.some((c) => c.cmd === "gh" && c.args[1] === "set"), false);
});

test("publish refuses when the p12 verification returns no names", async () => {
  const fake = makeFakeDeps({
    state: {
      identities: [CI_SIGNING_IDENTITY],
      ghStatus: 0,
      ghStdout: "",
      verifyStdout: "",
    },
  });
  const res = await publishCiSigningToGithub({ execute: true, deps: fake.deps });
  assert.equal(res.success, false);
  assert.equal(res.executed, false);
  assert.match(res.detail, /no certificate names/);
  assert.equal(fake.calls.some((c) => c.cmd === "gh" && c.args[1] === "set"), false);
});

test("publish refuses when security export succeeds but writes no file", async () => {
  const fake = makeFakeDeps({
    state: {
      identities: [CI_SIGNING_IDENTITY],
      ghStatus: 0,
      ghStdout: "",
      exportNoWrite: true,
    },
  });
  const res = await publishCiSigningToGithub({ execute: true, deps: fake.deps });
  assert.equal(res.success, false);
  assert.equal(res.executed, false);
  assert.equal(res.p12Base64, null);
  assert.match(res.detail, /wrote no file/);
  assert.equal(fake.calls.some((c) => c.cmd === "gh" && c.args[1] === "set"), false);
});

// ── Sign project (bundle-aware) ──────────────────────────────────────────────

/**
 * Minimal fake deps for signProject/signOneBinary/signBundle. The codesign
 * runner distinguishes sign (args[0]==="--force") from verify
 * (args[0]==="--verify") and simulates failures via state flags.
 */
function makeSignDeps(opts = {}) {
  const calls = [];
  const state = {
    identities: [SIGNING_IDENTITY],
    binariesPresent: true,
    bundlePresent: true,
    entitlementsPresent: true,
    signFail: false,
    verifyFail: false,
    ...(opts.state ?? {}),
  };
  const ok = (stdout = "", stderr = "") => ({ status: 0, stdout, stderr });
  const fail = (stderr = "") => ({ status: 1, stdout: "", stderr });

  const runFn = async (cmd, args = [], ropts) => {
    calls.push({ cmd, args, opts: ropts });
    if (cmd === "security" && args[0] === "find-identity") {
      const lines = state.identities.map((n, i) => `${i + 1}) ${"AB".repeat(20)} "${n}"`).join("\n");
      return ok(lines);
    }
    if (cmd === "codesign") {
      if (args[0] === "--verify") {
        return state.verifyFail ? fail("code object is not signed at all") : ok();
      }
      return state.signFail ? fail("CodeSign operation failed") : ok();
    }
    throw new Error(`unhandled fake command: ${cmd} ${args.join(" ")}`);
  };

  const existsFn = (p) => {
    if (p.endsWith(".entitlements")) return state.entitlementsPresent;
    if (p.endsWith("/NanoDictateAgent") || p.endsWith("/nanodictate")) return state.binariesPresent;
    if (p.endsWith(`/${APP_BUNDLE_NAME}`)) return state.bundlePresent;
    return false;
  };

  return { calls, state, deps: { runFn, existsFn } };
}

/** The codesign sign call whose args reference the given path. */
function signCallFor(fake, path) {
  return fake.calls.find((c) => c.cmd === "codesign" && c.args[0] === "--force" && c.args.includes(path));
}

test("signProject signs both binaries and the bundle with identical flags and no --deep", async () => {
  const fake = makeSignDeps();
  const res = await signProject("debug", fake.deps);

  assert.equal(res.success, true);
  assert.equal(res.binaries.length, 3);
  assert.equal(res.binaries[0].name, "NanoDictateAgent");
  assert.equal(res.binaries[1].name, "nanodictate");
  assert.equal(res.binaries[2].name, APP_BUNDLE_NAME);
  assert.equal(res.binaries[2].signed, true);
  assert.equal(res.binaries[2].verified, true);

  const bundlePath = binaryPaths("debug").appBundle;
  const sign = signCallFor(fake, bundlePath);
  assert.ok(sign, "bundle codesign call exists");
  assert.ok(sign.args.includes("--force"));
  assert.ok(sign.args.includes("--sign"));
  assert.ok(sign.args.includes(SIGNING_IDENTITY));
  assert.ok(sign.args.includes("--options"));
  assert.ok(sign.args.includes("runtime"));
  assert.ok(sign.args.includes("--identifier"));
  assert.ok(sign.args.includes(AGENT_BUNDLE_ID));
  const ent = sign.args[sign.args.indexOf("--entitlements") + 1];
  assert.match(ent, /\.entitlements$/);
  assert.equal(sign.args.includes("--deep"), false, "no --deep: inner binaries are already signed");

  // each of the three paths gets both a sign and a verify call
  for (const p of [binaryPaths("debug").agent, binaryPaths("debug").nanodictate, bundlePath]) {
    assert.ok(fake.calls.some((c) => c.cmd === "codesign" && c.args[0] === "--verify" && c.args.includes(p)), `verify for ${p}`);
  }
});

test("signProject skips the bundle gracefully when only bare binaries were built", async () => {
  const fake = makeSignDeps({ state: { bundlePresent: false } });
  const res = await signProject("debug", fake.deps);

  assert.equal(res.success, true);
  assert.equal(res.binaries.length, 2);
  assert.equal(fake.calls.some((c) => c.cmd === "codesign" && c.args.join(" ").includes(APP_BUNDLE_NAME)), false);
});

test("signProject fails when the bundle verify fails", async () => {
  const fake = makeSignDeps({ state: { verifyFail: true } });
  const res = await signProject("release", fake.deps);

  assert.equal(res.success, false);
  const bundle = res.binaries[res.binaries.length - 1];
  assert.equal(bundle.name, APP_BUNDLE_NAME);
  assert.equal(bundle.signed, true);
  assert.equal(bundle.verified, false);
  assert.match(bundle.detail, /verify returned 1/);
  assert.match(res.detail, /could not be signed or verified/);
});

test("signProject fails when codesign fails, and still reports the failing binary", async () => {
  const fake = makeSignDeps({ state: { signFail: true } });
  const res = await signProject("debug", fake.deps);

  assert.equal(res.success, false);
  const bad = res.binaries.find((b) => !b.signed);
  assert.ok(bad, "a binary reports signed:false");
  assert.equal(bad.signed, false);
  assert.match(bad.detail, /codesign failed/);
});

test("signProject reports the missing identity without running codesign", async () => {
  const fake = makeSignDeps({ state: { identities: [] } });
  const res = await signProject("debug", fake.deps);

  assert.equal(res.success, false);
  assert.equal(res.binaries.length, 0);
  assert.equal(fake.calls.some((c) => c.cmd === "codesign"), false);
});

test("signOneBinary reports a missing binary as a graceful not-found result", async () => {
  const fake = makeSignDeps({ state: { binariesPresent: false } });
  const res = await signOneBinary("NanoDictateAgent", binaryPaths("debug").agent, "/no-such.entitlements", AGENT_BUNDLE_ID, fake.deps);

  assert.equal(res.signed, false);
  assert.equal(res.verified, false);
  assert.match(res.detail, /binary not found/);
  assert.equal(fake.calls.some((c) => c.cmd === "codesign"), false);
});

test("signOneBinary reports a missing entitlements file without running codesign", async () => {
  const fake = makeSignDeps({ state: { entitlementsPresent: false } });
  const res = await signOneBinary("nanodictate", binaryPaths("debug").nanodictate, "/absent.entitlements", NANODICTATE_BUNDLE_ID, fake.deps);

  assert.equal(res.signed, false);
  assert.match(res.detail, /entitlements file missing/);
  assert.equal(fake.calls.some((c) => c.cmd === "codesign"), false);
});

test("signBundle returns null for a bundle-less build and signs when present", async () => {
  const absent = makeSignDeps({ state: { bundlePresent: false } });
  assert.equal(await signBundle("debug", "/x.entitlements", absent.deps), null);

  const present = makeSignDeps();
  const res = await signBundle("debug", "/x.entitlements", present.deps);
  assert.equal(res.name, APP_BUNDLE_NAME);
  assert.equal(res.path, binaryPaths("debug").appBundle);
  assert.equal(res.signed, true);
  assert.equal(res.verified, true);
});
