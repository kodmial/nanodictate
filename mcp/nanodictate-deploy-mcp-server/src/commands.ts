/**
 * Low-level command wrappers used by the MCP tool handlers.
 *
 * All functions return plain data objects (never throw) so the tool handlers
 * can compose results into structuredContent or markdown without catch blocks
 * leaking into the MCP protocol layer.
 */

import { spawn } from "node:child_process";
import {
  accessSync,
  constants as fsConstants,
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { randomBytes } from "node:crypto";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import {
  ACCESSIBILITY_STAMP_KEY,
  AGENT_BUNDLE_ID,
  AGENT_SERVICE_NAME,
  APP_BUNDLE_NAME,
  BUILD_TIMEOUT_MS,
  CI_P12_PASSWORD_SECRET,
  CI_P12_SECRET,
  CI_SIGNING_IDENTITY,
  COMMAND_TIMEOUT_MS,
  MACPORTS_PORT_BIN,
  NANODICTATE_BUNDLE_ID,
  NANODICTATE_TAP,
  PARTITION_TIMEOUT_MS,
  TCC_GRANTS_DELETE_CMD,
  TCC_GRANTS_SELECT_CMD,
  ENTITLEMENTS_AGENT_FILE,
  ENTITLEMENTS_NANODICTATE_FILE,
  OUTPUT_TAIL_LINES,
  PROJECT_ROOT,
  SIGNING_IDENTITY,
  type Configuration,
  binaryPaths,
  resolveEntitlementsPath,
  tapCloneDir,
  tapCloneFallbackDir,
  wipePaths,
} from "./constants.js";

// ── Helpers ─────────────────────────────────────────────────────────────────

export interface RunResult {
  status: number;
  stdout: string;
  stderr: string;
}

export interface RunOptions {
  cwd?: string;
  timeoutMs?: number;
  /** Extra environment variables merged over the inherited environment. */
  env?: Record<string, string | undefined>;
  /**
   * Data written to the child's stdin. When set, stdin is piped and the data is
   * written once the child spawns; when omitted stdin is /dev/null, so secrets
   * never travel through the argv in commands that read from stdin.
   */
  input?: string;
}

/** Signature of the process runner — injectable so tests never spawn real commands. */
export type RunFn = (
  cmd: string,
  args: string[],
  opts?: RunOptions,
) => Promise<RunResult>;

/** Signature of the path probe — injectable so tests use fake filesystems. */
export type ExistsFn = (path: string) => boolean;

/**
 * Execution context shared by the wipe / certificate commands. Every field can
 * be injected, so unit tests drive the full orchestration without touching the
 * real filesystem, brew, macports, launchctl or the keychain.
 */
export interface CommandDeps {
  runFn: RunFn;
  existsFn: ExistsFn;
  home: string;
  uid: string;
}

/** Default path probe: plain existsSync. */
const defaultExists: ExistsFn = (path) => existsSync(path);

/**
 * Merge injected dependencies over the real ones. `uid` is resolved with
 * `id -u` (same source as restartAgent/getStatus) unless injected.
 */
export async function resolveCommandDeps(
  partial: Partial<CommandDeps> = {},
): Promise<CommandDeps> {
  let uid = partial.uid;
  if (uid === undefined) {
    uid = (await run("id", ["-u"])).stdout.trim();
  }
  return {
    runFn: partial.runFn ?? run,
    existsFn: partial.existsFn ?? defaultExists,
    home: partial.home ?? homedir(),
    uid,
  };
}

/**
 * Spawn a child process and collect stdout / stderr.
 * On timeout the process is SIGKILL'd and status is set to −1.
 * Never throws — callers always get a RunResult.
 */
export function run(
  cmd: string,
  args: string[],
  opts: RunOptions = {},
): Promise<RunResult> {
  return new Promise<RunResult>((resolve) => {
    const pipeStdin = opts.input !== undefined;
    const child = spawn(cmd, args, {
      cwd: opts.cwd,
      env: opts.env ? { ...process.env, ...opts.env } : undefined,
      stdio: [pipeStdin ? "pipe" : "ignore", "pipe", "pipe"],
    });

    if (pipeStdin && child.stdin) {
      // A child may close stdin early (exit, crash) before consuming all input.
      // Swallow EPIPE-style write errors — the exit status is authoritative.
      child.stdin.on("error", () => {});
      child.stdin.end(opts.input);
    }

    let stdout = "";
    let stderr = "";
    let killedByTimeout = false;

    const timeoutMs = opts.timeoutMs ?? COMMAND_TIMEOUT_MS;
    const timer = setTimeout(() => {
      killedByTimeout = true;
      child.kill("SIGKILL");
    }, timeoutMs);

    // stdout/stderr are always "pipe" in the stdio tuple above; the non-null
    // assertions are safe because only index 0 (stdin) ever varies.
    child.stdout!.on("data", (chunk: Buffer) => {
      stdout += chunk.toString();
    });
    child.stderr!.on("data", (chunk: Buffer) => {
      stderr += chunk.toString();
    });
    child.on("error", (err) => {
      clearTimeout(timer);
      resolve({ status: -1, stdout, stderr: stderr || err.message });
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      if (killedByTimeout) {
        resolve({
          status: -1,
          stdout,
          stderr: stderr + `\n(TIMEOUT after ${timeoutMs} ms — process killed)`,
        });
      } else {
        resolve({ status: code ?? -1, stdout, stderr });
      }
    });
  });
}

/** Return the last `n` non-empty lines from a string. */
export function tail(text: string, n: number = OUTPUT_TAIL_LINES): string {
  return text
    .split("\n")
    .filter((line) => line.length > 0)
    .slice(-n)
    .join("\n");
}

// ── Toolchain resolution ────────────────────────────────────────────────────

export interface SwiftToolchain {
  /** Command used to invoke the Swift compiler (absolute path or `swift`). */
  swift: string;
  /** Extra environment variables needed for `swift build` to parse the manifest. */
  env: Record<string, string>;
  /** Where the toolchain came from. */
  source: "SWIFT_TOOLCHAIN" | "PATH";
}

export type ToolchainResolution =
  | { ok: true; toolchain: SwiftToolchain }
  | { ok: false; error: string };

/** True if the file exists and is executable. */
function isExecutable(file: string): boolean {
  try {
    accessSync(file, fsConstants.X_OK);
    return true;
  } catch {
    return false;
  }
}

/** First `name` found on a colon-separated PATH with the exec bit set. */
function findOnPath(name: string, pathEnv: string | undefined): string | null {
  if (!pathEnv) return null;
  for (const dir of pathEnv.split(":")) {
    if (!dir) continue;
    const candidate = join(dir, name);
    if (isExecutable(candidate)) return candidate;
  }
  return null;
}

/**
 * Resolve the Swift toolchain 1:1 with the removed build.sh in the main checkout:
 *
 *   - SWIFT_TOOLCHAIN set and `$SWIFT_TOOLCHAIN/usr/bin/swift` executable → use
 *     that toolchain and pass SWIFT_EXEC_MANIFEST / SWIFTPM_CUSTOM_LIBS_DIR for
 *     spawn (the Command Line Tools install lacks PackageDescription.swiftmodule,
 *     so plain `swift build` cannot compile the manifest);
 *   - otherwise `swift` from PATH;
 *   - otherwise a readable error naming the required fix.
 *
 * `env` is injected so tests can drive every branch without touching process.env.
 */
export function resolveSwiftToolchain(
  env: NodeJS.ProcessEnv = process.env,
): ToolchainResolution {
  const custom = env.SWIFT_TOOLCHAIN;
  if (custom) {
    const swiftPath = join(custom, "usr", "bin", "swift");
    if (isExecutable(swiftPath)) {
      return {
        ok: true,
        toolchain: {
          swift: swiftPath,
          env: {
            SWIFT_EXEC_MANIFEST: join(custom, "usr", "bin", "swiftc"),
            SWIFTPM_CUSTOM_LIBS_DIR: join(custom, "usr", "lib", "swift", "pm"),
          },
          source: "SWIFT_TOOLCHAIN",
        },
      };
    }
    return {
      ok: false,
      error:
        `SWIFT_TOOLCHAIN is set to "${custom}" but no executable swift at ${swiftPath}. ` +
        `Fix the variable, or unset it to fall back to the swift on PATH.`,
    };
  }

  const fromPath = findOnPath("swift", env.PATH);
  if (fromPath) {
    return { ok: true, toolchain: { swift: fromPath, env: {}, source: "PATH" } };
  }

  return {
    ok: false,
    error:
      `'swift' not found in PATH and SWIFT_TOOLCHAIN not set. ` +
      `Install Xcode Command Line Tools (xcode-select --install), or set SWIFT_TOOLCHAIN to a toolchain.`,
  };
}

// ── Build ───────────────────────────────────────────────────────────────────

const NANODICTATE_SYMLINK = "/usr/local/bin/nanodictate";

export interface SymlinkResult {
  created: boolean;
  /** Absolute path to the freshly built binary. */
  target: string;
  /** The symlink itself. */
  linkPath: string;
  detail: string;
}

export interface BuildResult {
  configuration: Configuration;
  success: boolean;
  exitCode: number;
  binaryPath: string;
  symlink: SymlinkResult;
  tail: string;
}

/** True if the directory exists and is writable by this user. */
function isWritableDir(dir: string): boolean {
  try {
    accessSync(dir, fsConstants.W_OK);
    return true;
  } catch {
    return false;
  }
}

/**
 * `ln -sf .build/{configuration}/nanodictate /usr/local/bin/nanodictate`,
 * configuration-aware (mirrors the symlink step in the removed build.sh). If /usr/local/bin
 * is missing or not writable the function returns a WARNING (created: false) —
 * the build itself still succeeded, so this must never fail the whole result.
 */
export async function createNanodictateSymlink(
  configuration: Configuration,
): Promise<SymlinkResult> {
  const target = binaryPaths(configuration).nanodictate;
  const linkPath = NANODICTATE_SYMLINK;
  const linkDir = linkPath.slice(0, linkPath.lastIndexOf("/"));

  if (!existsSync(linkDir) || !isWritableDir(linkDir)) {
    return {
      created: false,
      target,
      linkPath,
      detail:
        `WARNING: ${linkDir} is missing or not writable — symlink NOT created. ` +
        `Run \`sudo chown $(whoami) ${linkDir}\`, or use a ~/bin on your PATH.`,
    };
  }

  const res = await run("ln", ["-sf", target, linkPath]);
  return {
    created: res.status === 0,
    target,
    linkPath,
    detail:
      res.status === 0
        ? `symlink created: ${linkPath} → ${target}`
        : `ln -sf failed (exit ${res.status}): ${res.stderr.trim() || "(no output)"}`,
  };
}

/** Run `swift build -c <configuration>` in the main checkout. */
export async function buildProject(
  configuration: Configuration,
): Promise<BuildResult> {
  const paths = binaryPaths(configuration);
  const toolchain = resolveSwiftToolchain();

  if (!toolchain.ok) {
    return {
      configuration,
      success: false,
      exitCode: -1,
      binaryPath: paths.agent,
      symlink: {
        created: false,
        target: paths.nanodictate,
        linkPath: NANODICTATE_SYMLINK,
        detail: "build not run — " + toolchain.error,
      },
      tail: toolchain.error,
    };
  }

  const res = await run(toolchain.toolchain.swift, ["build", "-c", configuration], {
    cwd: PROJECT_ROOT,
    timeoutMs: BUILD_TIMEOUT_MS,
    env: toolchain.toolchain.env,
  });
  const buildOk = res.status === 0 && existsSync(paths.agent);
  const symlink =
    buildOk
      ? await createNanodictateSymlink(configuration)
      : {
          created: false,
          target: paths.nanodictate,
          linkPath: NANODICTATE_SYMLINK,
          detail: "build failed — symlink not created",
        };

  return {
    configuration,
    success: buildOk,
    exitCode: res.status,
    binaryPath: paths.agent,
    symlink,
    tail: tail(res.stdout + "\n" + res.stderr),
  };
}

// ── Signing identity ────────────────────────────────────────────────────────

export interface IdentityCheck {
  found: boolean;
  detail: string;
}

/**
 * Pure matcher over `security find-identity -p codesigning -v` stdout.
 * Extracted from checkSigningIdentity so the matching logic is unit-testable.
 */
export function matchSigningIdentity(
  stdout: string,
  identity: string,
): IdentityCheck {
  const lines = stdout.split("\n");
  const matchLine = lines.find((l) => l.includes(`"${identity}"`));

  if (matchLine) {
    return { found: true, detail: matchLine.trim() };
  }
  const identities = lines
    .filter((l) => l.includes(")"))
    .map((l) => l.trim());
  return {
    found: false,
    detail:
      `"${identity}" not found in keychain. ` +
      (identities.length
        ? `Available identities:\n${identities.join("\n")}`
        : "No identities found at all. Create a 'NanoDictate Code Signing' certificate via Keychain Access → Certificate Assistant."),
  };
}

/** Return whether the signing identity is available in the keychain. */
export async function checkSigningIdentity(
  runFn: RunFn = run,
): Promise<IdentityCheck> {
  const res = await runFn("security", [
    "find-identity",
    "-p",
    "codesigning",
    "-v",
  ]);
  return matchSigningIdentity(res.stdout, SIGNING_IDENTITY);
}

// ── Sign a binary ───────────────────────────────────────────────────────────

export interface SignBinaryResult {
  name: string;
  path: string;
  signed: boolean;
  verified: boolean;
  detail: string;
}

/** Injectable deps for the sign helpers (process runner + path probe). */
export interface SignBinaryDeps {
  runFn?: RunFn;
  existsFn?: ExistsFn;
}

/**
 * Sign one binary (or the .app bundle, which codesign treats the same way)
 * with the stable identity and the same flags:
 *   codesign --force --sign <identity> --entitlements <file>
 *            --options runtime --identifier <bundleId> <path>
 * then codesign --verify --strict. A missing binary (bundle not built by a
 * plain `swift build`) is a graceful skip — signed:false, never a throw.
 */
export async function signOneBinary(
  name: string,
  binaryPath: string,
  entitlementsPath: string,
  bundleId: string,
  deps: SignBinaryDeps = {},
): Promise<SignBinaryResult> {
  const exists = deps.existsFn ?? defaultExists;
  const runner = deps.runFn ?? run;
  if (!exists(binaryPath)) {
    return {
      name,
      path: binaryPath,
      signed: false,
      verified: false,
      detail: "binary not found — run dictation_build first",
    };
  }
  if (!exists(entitlementsPath)) {
    return {
      name,
      path: binaryPath,
      signed: false,
      verified: false,
      detail: `entitlements file missing: ${entitlementsPath}`,
    };
  }

  const signRes = await runner(
    "codesign",
    [
      "--force",
      "--sign",
      SIGNING_IDENTITY,
      "--entitlements",
      entitlementsPath,
      "--options",
      "runtime",
      "--identifier",
      bundleId,
      binaryPath,
    ],
    { timeoutMs: COMMAND_TIMEOUT_MS },
  );

  if (signRes.status !== 0) {
    return {
      name,
      path: binaryPath,
      signed: false,
      verified: false,
      detail: `codesign failed (exit ${signRes.status}): ${signRes.stderr.trim()}`,
    };
  }

  const verifyRes = await runner(
    "codesign",
    ["--verify", "--strict", "--verbose=2", binaryPath],
    { timeoutMs: COMMAND_TIMEOUT_MS },
  );

  return {
    name,
    path: binaryPath,
    signed: true,
    verified: verifyRes.status === 0,
    detail:
      verifyRes.status === 0
        ? "signed and verified"
        : `signed but verify returned ${verifyRes.status}: ${verifyRes.stderr.trim()}`,
  };
}

/**
 * Sign the .app bundle when the packaging layer built one. The inner binaries
 * under Contents/MacOS/ are ALREADY signed by signProject's two main calls, so
 * the bundle is signed with the SAME flags and NO --deep. A missing bundle
 * (plain `swift build` — no packaging step) is a graceful skip: null, so
 * signProject never fails on a bundle-less build.
 */
export async function signBundle(
  configuration: Configuration,
  entitlementsPath: string,
  deps: SignBinaryDeps = {},
): Promise<SignBinaryResult | null> {
  const exists = deps.existsFn ?? defaultExists;
  const bundlePath = binaryPaths(configuration).appBundle;
  if (!exists(bundlePath)) {
    return null;
  }
  return signOneBinary(
    APP_BUNDLE_NAME,
    bundlePath,
    entitlementsPath,
    AGENT_BUNDLE_ID,
    deps,
  );
}

// ── Sign project ────────────────────────────────────────────────────────────

export interface SignResult {
  success: boolean;
  configuration: Configuration;
  identity: string;
  binaries: SignBinaryResult[];
  detail: string;
}

/**
 * Sign NanoDictateAgent, nanodictate, and — when the packaging layer built one —
 * the .app bundle holding both as siblings under Contents/MacOS/. The bundle is
 * optional: a plain `swift build` produces only the bare binaries, and a missing
 * bundle is a graceful skip, never a failure.
 */
export async function signProject(
  configuration: Configuration,
  deps: SignBinaryDeps = {},
): Promise<SignResult> {
  const identity = await checkSigningIdentity(deps.runFn);
  if (!identity.found) {
    return {
      success: false,
      configuration,
      identity: SIGNING_IDENTITY,
      binaries: [],
      detail: identity.detail,
    };
  }

  const paths = binaryPaths(configuration);
  const agentEntitlements = resolveEntitlementsPath(ENTITLEMENTS_AGENT_FILE);
  const ctlEntitlements = resolveEntitlementsPath(ENTITLEMENTS_NANODICTATE_FILE);
  const [agentBin, ctlBin, bundleBin] = await Promise.all([
    signOneBinary(
      "NanoDictateAgent",
      paths.agent,
      agentEntitlements.path,
      AGENT_BUNDLE_ID,
      deps,
    ),
    signOneBinary(
      "nanodictate",
      paths.nanodictate,
      ctlEntitlements.path,
      NANODICTATE_BUNDLE_ID,
      deps,
    ),
    signBundle(configuration, agentEntitlements.path, deps),
  ]);

  const allSigned = agentBin.signed && ctlBin.signed;
  const allVerified = agentBin.verified && ctlBin.verified;
  const bundleOK = bundleBin === null || (bundleBin.signed && bundleBin.verified);
  const success = allSigned && allVerified && bundleOK;

  const binaries: SignBinaryResult[] = [agentBin, ctlBin];
  if (bundleBin !== null) {
    binaries.push(bundleBin);
  }

  return {
    success,
    configuration,
    identity: SIGNING_IDENTITY,
    binaries,
    detail: success
      ? "All binaries signed and verified"
      : "Some binaries could not be signed or verified",
  };
}

// ── Restart agent ───────────────────────────────────────────────────────────

export interface RestartResult {
  success: boolean;
  method: string;
  detail: string;
}

/** Restart the LaunchAgent via `launchctl kickstart -k`. Fallback to `nanodictate start`. */
export async function restartAgent(): Promise<RestartResult> {
  const uid = (await run("id", ["-u"])).stdout.trim();
  const target = `gui/${uid}/${AGENT_SERVICE_NAME}`;

  const kick = await run("/bin/launchctl", ["kickstart", "-k", target]);
  if (kick.status === 0) {
    return {
      success: true,
      method: "launchctl kickstart -k",
      detail: `Agent restarted via ${target}`,
    };
  }

  // Fallback: nanodictate start (takeover: bootout → rewrites canonical
  // ~/Library/LaunchAgents/com.nanodictate.agent.plist → bootstrap; re-registers
  // the service with the current binary path if kickstart failed)
  const dictctlPath = existsSync("/usr/local/bin/nanodictate")
    ? "/usr/local/bin/nanodictate"
    : "nanodictate";
  const fallback = await run(dictctlPath, ["start"]);
  const fallbackOutput = (fallback.stdout + "\n" + fallback.stderr).trim();

  return {
    success: fallback.status === 0,
    method: "nanodictate start (fallback)",
    detail:
      `kickstart failed (${kick.stderr.trim() || "exit " + kick.status}). ` +
      `Fallback: ${fallbackOutput || "no output"}`,
  };
}

// ── Status ──────────────────────────────────────────────────────────────────

export interface CodeSignatureInfo {
  signed: boolean;
  identity: string | null;
  teamId: string | null;
  entitlements: Record<string, unknown> | null;
  /** Resolved entitlements file used for signing, if present in a checkout. */
  entitlementsFile: string | null;
}

/**
 * Normalize a `TeamIdentifier=…` value parsed from `codesign -dv` output.
 * Self-signed certificates print "TeamIdentifier=not set" — those have no team
 * id, so they normalize to null.
 */
export function parseTeamId(raw: string | null | undefined): string | null {
  if (!raw) return null;
  const trimmed = raw.trim();
  const lower = trimmed.toLowerCase();
  return lower === "not" || lower === "not set" ? null : trimmed;
}

export interface StatusResult {
  agentRunning: boolean;
  pids: number[];
  launchAgentLoaded: boolean;
  launchAgentDetail: string;
  binaryPath: string | null;
  codeSignature: CodeSignatureInfo | null;
  signatureStable: boolean;
}

/** Parse key/value pairs from `codesign -d --entitlements -` XML output. */
export function parseEntitlements(xml: string): Record<string, unknown> | null {
  if (!xml.includes("<dict>")) return null;
  const result: Record<string, unknown> = {};
  const re =
    /<key>([^<]+)<\/key>\s*(<(?:true|false)\/>|<string>([^<]*)<\/string>|<integer>(\d+)<\/integer>)/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(xml)) !== null) {
    const [, key, rawVal] = m;
    if (rawVal.startsWith("<true")) result[key] = true;
    else if (rawVal.startsWith("<false")) result[key] = false;
    else if (rawVal.startsWith("<string>")) result[key] = m[3];
    else if (rawVal.startsWith("<integer>")) result[key] = parseInt(m[4], 10);
  }
  return Object.keys(result).length > 0 ? result : null;
}

/** Gather process, launchd and code-signature status. */
export async function getStatus(
  configuration: Configuration,
): Promise<StatusResult> {
  const uid = (await run("id", ["-u"])).stdout.trim();
  const agentService = `gui/${uid}/${AGENT_SERVICE_NAME}`;

  // 1. Process check
  const pgrep = await run("/usr/bin/pgrep", ["-f", "NanoDictateAgent"]);
  const pids =
    pgrep.status === 0
      ? pgrep.stdout
          .trim()
          .split(/\s+/)
          .map((s) => parseInt(s, 10))
          .filter((n) => !Number.isNaN(n))
      : [];

  // 2. launchctl check
  const launch = await run("/bin/launchctl", ["print", agentService]);

  // 3. Code signature check
  const paths = binaryPaths(configuration);
  const agentPath = existsSync(paths.agent) ? paths.agent : null;
  const agentEntitlements = resolveEntitlementsPath(ENTITLEMENTS_AGENT_FILE);

  let codeSignature: CodeSignatureInfo | null = null;
  if (agentPath) {
    const dv = await run("codesign", ["-dv", "--verbose=2", agentPath]);

    // codesign -dv prints diagnostic info to stderr
    const rawInfo = (dv.stderr || dv.stdout).trim();
    const authorityMatch = rawInfo.match(/Authority=(.+)/);
    // Self-signed certs have no team id — codesign prints "TeamIdentifier=not set".
    const teamMatch = rawInfo.match(/TeamIdentifier=(\w+)/);

    const entitlementDump = await run("codesign", [
      "-d",
      "--entitlements",
      "-",
      agentPath,
    ]);
    const entitlements = parseEntitlements(
      entitlementDump.stdout + entitlementDump.stderr,
    );

    codeSignature = {
      signed: dv.status === 0,
      identity: authorityMatch?.[1] ?? null,
      teamId: parseTeamId(teamMatch?.[1]),
      entitlements,
      entitlementsFile:
        agentEntitlements.source === "missing"
          ? null
          : agentEntitlements.path,
    };
  }

  const signatureStable =
    !!codeSignature &&
    codeSignature.signed &&
    codeSignature.identity === SIGNING_IDENTITY;

  return {
    agentRunning: pids.length > 0,
    pids,
    launchAgentLoaded: launch.status === 0,
    launchAgentDetail: tail(launch.stdout + launch.stderr, 15),
    binaryPath: agentPath,
    codeSignature,
    signatureStable,
  };
}

// ── Probe parsers (pure, unit-testable) ─────────────────────────────────────

/**
 * True when `brew list --versions` output lists the nanodictate formula
 * (`nanodictate 0.0.12`).
 */
export function matchBrewList(stdout: string): boolean {
  return stdout
    .split("\n")
    .some((line) => /^nanodictate\s+\S+/.test(line.trim()));
}

/**
 * True when `port installed nanodictate` output lists the port
 * (`nanodictate @0.0.12_0 ...`). MacPorts answers "None of the specified ports
 * are installed." with exit code 0 when the port is absent, so the probe must
 * match the port line, never the exit code alone.
 */
export function matchPortInstalled(text: string): boolean {
  return text
    .split("\n")
    .some((line) => /^nanodictate\s+@\S+/.test(line.trim()));
}

/** PIDs from `pgrep -f` stdout. */
export function parsePgrep(stdout: string): number[] {
  return stdout
    .trim()
    .split(/\s+/)
    .map((s) => parseInt(s, 10))
    .filter((n) => !Number.isNaN(n));
}

/** File paths from `find <dir> -maxdepth 1 -name '*nanodictate*'` stdout. */
export function findNanodictatePaths(stdout: string): string[] {
  return stdout
    .split("\n")
    .map((l) => l.trim())
    .filter((l) => l.length > 0 && /nanodictate/i.test(l));
}

export interface IdentityEntry {
  sha1: string;
  name: string;
}

/** Parse `security find-identity -p codesigning -v` lines: `1) SHA1 "Name"`. */
export function parseFindIdentity(stdout: string): IdentityEntry[] {
  const out: IdentityEntry[] = [];
  for (const line of stdout.split("\n")) {
    const m = line.match(/^\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"([^"]+)"/);
    if (m) out.push({ sha1: m[1].toUpperCase(), name: m[2] });
  }
  return out;
}

/** Code-signing identities present in the local keychain (never throws). */
export async function listCodeSigningIdentities(
  deps: CommandDeps,
): Promise<IdentityEntry[]> {
  const res = await deps.runFn("security", [
    "find-identity",
    "-p",
    "codesigning",
    "-v",
  ]);
  if (res.status !== 0) return [];
  return parseFindIdentity(res.stdout);
}

// ── dictation_wipe ──────────────────────────────────────────────────────────

export interface TapCloneResolution {
  path: string;
  source: "brew" | "arch-fallback";
}

/**
 * Resolve the local tap clone directory. `brew --repository` prints the true
 * Homebrew repository dir (HOMEBREW_PREFIX on Apple Silicon = /opt/homebrew;
 * on Intel = /usr/local/Homebrew — the nested /Homebrew exists only in the
 * Intel/Linux layout). Falls back to the arch constant when brew is missing
 * or prints nothing; `arch` is injectable so tests pin both layouts.
 */
export async function resolveTapCloneDir(
  runFn: RunFn,
  arch: string = process.arch,
): Promise<TapCloneResolution> {
  const res = await runFn("brew", ["--repository"]);
  const repo = res.status === 0 ? res.stdout.trim().split("\n")[0] ?? "" : "";
  if (repo) return { path: tapCloneDir(repo), source: "brew" };
  return { path: tapCloneFallbackDir(arch), source: "arch-fallback" };
}

export type WipeItemStatus =
  | "clean"
  | "dryrun"
  | "wiped"
  | "failed"
  | "manual-sudo";

export interface WipeItemReport {
  id: string;
  label: string;
  status: WipeItemStatus;
  detail: string;
  /** Exact command the user must run by hand (manual-sudo items only). */
  command: string | null;
}

export interface WipeResult {
  success: boolean;
  dryRun: boolean;
  items: WipeItemReport[];
  newcomerReady: boolean;
  manualCommands: string[];
  leftover: string[];
  pidsAfter: number[];
  detail: string;
}

export interface WipeOptions {
  /** true (default) = probe and report only, nothing is deleted. */
  dryRun?: boolean;
  deps?: Partial<CommandDeps>;
}

interface ProbeResult {
  found: boolean;
  detail?: string;
}

interface ActResult {
  ok: boolean;
  detail: string;
}

interface WipeStep {
  id: string;
  label: string;
  probe: () => Promise<ProbeResult>;
  act?: () => Promise<ActResult>;
  verify?: () => Promise<boolean>;
  /** Set for root-owned targets: never attempted non-interactively. */
  manualCommand?: string;
}

/**
 * id of the always-manual TCC step. The agent cannot read the TCC databases
 * (Accessibility in the system db + Microphone in the per-user db; SIP +
 * interactive sudo, and the system db additionally needs Full Disk Access), so
 * this step is never probed or acted — it only hands the exact sudo command to
 * the user. It is excluded from newcomer readiness and leftover, because a
 * file-clean machine must stay newcomer-ready regardless of TCC state.
 */
export const TCC_RECORDS_STEP_ID = "tccRecords";

/**
 * Comment line labelling the TCC manual CHECK (read-only SELECT) inside the
 * sh-block output ("# TCC-grants-check (проверка; c>1 = дубли)"). Precedes the
 * SELECT command line, so the block stays safe to copy-paste: shell comments
 * are ignored, the command body carries no label.
 */
export const TCC_GRANTS_CHECK_LABEL = "# TCC-grants-check (проверка; c>1 = дубли)";

/**
 * Comment line labelling the TCC manual command inside the sh-block output
 * ("# TCC-grants"). The comment precedes the command line, so the block stays
 * safe to copy-paste: the comment is ignored by the shell, the command body
 * carries no label. The "TCC-grants" word remains in the output by contract.
 */
export const TCC_GRANTS_LABEL = "# TCC-grants";

/** Note appended to the wipe detail: TCC grants are erased manually, not by the agent. */
const TCC_MANUAL_NOTE =
  "TCC Accessibility/Microphone grants are erased manually — run the 'TCC-grants-check' (see what is recorded, c>1 = duplicates) and 'TCC-grants' sudo commands below (both optional/no-op when no records exist).";

/**
 * One probe → act → verify cycle. Nothing is executed unless the probe found
 * something AND the run is not a dry run AND the item is not manual-sudo.
 */
async function runWipeStep(step: WipeStep, dryRun: boolean): Promise<WipeItemReport> {
  const probe = await step.probe();

  if (!probe.found) {
    return {
      id: step.id,
      label: step.label,
      status: "clean",
      detail: probe.detail ?? "not present — nothing to delete",
      command: null,
    };
  }

  const base = { id: step.id, label: step.label, command: null as string | null };

  if (step.manualCommand) {
    return {
      ...base,
      status: "manual-sudo",
      detail: `present — needs root; run the command by hand (never attempted non-interactively). ${probe.detail ?? ""}`.trim(),
      command: step.manualCommand,
    };
  }

  if (dryRun) {
    return {
      ...base,
      status: "dryrun",
      detail: `present — would delete (dry run: nothing was executed). ${probe.detail ?? ""}`.trim(),
    };
  }

  if (!step.act) {
    return {
      ...base,
      status: "clean",
      detail: probe.detail ?? "nothing to delete",
    };
  }

  const act = await step.act();
  const verified = step.verify ? await step.verify() : act.ok;
  return {
    ...base,
    status: act.ok && verified ? "wiped" : "failed",
    detail: act.detail,
  };
}

/**
 * Idempotent wipe of every nanodictate trace this repo can create.
 *
 * Every item is probed first; a delete runs only for items the probe found, so
 * running this twice on a clean machine deletes nothing and still reports
 * success (newcomerReady). Root-owned targets are reported with the exact
 * command instead of being attempted. TCC Accessibility/Microphone grants are
 * never deleted by the agent — the TCC databases (system + per-user) are
 * unreadable without FDA/interactive sudo, so that step is always reported as
 * manual with the exact sudo command (and explicitly excluded from newcomer
 * readiness). The
 * GitHub repo/tap/manifests and foreign applications are never touched.
 */
export async function wipeProject(opts: WipeOptions = {}): Promise<WipeResult> {
  const dryRun = opts.dryRun ?? true;
  const deps = await resolveCommandDeps(opts.deps);
  const paths = wipePaths(deps.home);
  // Runtime-resolve the tap clone dir from `brew --repository` (the arch
  // constant baked into wipePaths is only the fallback for a missing brew).
  paths.tapClone = (await resolveTapCloneDir(deps.runFn)).path;

  const items: WipeItemReport[] = [];
  const manualCommands: string[] = [];
  const leftover: string[] = [];

  const record = async (step: WipeStep): Promise<WipeItemReport> => {
    const report = await runWipeStep(step, dryRun);
    items.push(report);
    if (report.command) manualCommands.push(report.command);
    if (report.status === "failed" || report.status === "manual-sudo") {
      leftover.push(report.id);
    }
    return report;
  };

  const rmItem = (path: string, id: string, label: string, rmFlag: string) => ({
    id,
    label,
    probe: async (): Promise<ProbeResult> => ({ found: deps.existsFn(path) }),
    act: async (): Promise<ActResult> => {
      const res = await deps.runFn("/bin/rm", [rmFlag, path]);
      return { ok: res.status === 0, detail: `rm ${rmFlag} ${path} → exit ${res.status}` };
    },
    verify: async (): Promise<boolean> => !deps.existsFn(path),
  });

  // 1. Homebrew formula
  await record({
    id: "brewFormula",
    label: "Homebrew formula nanodictate",
    probe: async () => {
      const res = await deps.runFn("brew", ["list", "--versions"]);
      const found = matchBrewList(res.stdout);
      return {
        found,
        detail: found ? tail(res.stdout, 3) : `brew list --versions exit ${res.status}`,
      };
    },
    act: async () => {
      const res = await deps.runFn("brew", ["uninstall", "--force", "nanodictate"]);
      return {
        ok: res.status === 0,
        detail: `brew uninstall --force nanodictate → exit ${res.status}${res.stderr.trim() ? `: ${tail(res.stderr, 2)}` : ""}`,
      };
    },
    verify: async () => !matchBrewList((await deps.runFn("brew", ["list", "--versions"])).stdout),
  });

  // 2. Local tap clone (formula source; removed only when it exists)
  await record({
    id: "brewTapClone",
    label: `Local tap clone ${NANODICTATE_TAP}`,
    probe: async () => ({ found: deps.existsFn(paths.tapClone) }),
    act: async () => {
      const untap = await deps.runFn("brew", ["untap", NANODICTATE_TAP]);
      let rmExit = 0;
      if (deps.existsFn(paths.tapClone)) {
        rmExit = (await deps.runFn("/bin/rm", ["-rf", paths.tapClone])).status;
      }
      return {
        ok: untap.status === 0 || !deps.existsFn(paths.tapClone),
        detail: `brew untap ${NANODICTATE_TAP} → exit ${untap.status}; rm -rf → exit ${rmExit}`,
      };
    },
    verify: async () => !deps.existsFn(paths.tapClone),
  });

  // 3. Homebrew download caches
  const findCaches = () =>
    deps.runFn("/usr/bin/find", [
      paths.downloadsCache,
      "-maxdepth",
      "1",
      "-name",
      "*nanodictate*",
    ]);
  await record({
    id: "brewCaches",
    label: "Homebrew download caches (*nanodictate*)",
    probe: async () => {
      if (!deps.existsFn(paths.downloadsCache)) {
        return { found: false, detail: `${paths.downloadsCache} not present` };
      }
      const cached = findNanodictatePaths((await findCaches()).stdout);
      return {
        found: cached.length > 0,
        detail: cached.length ? cached.join(", ") : "no matching cached files",
      };
    },
    act: async () => {
      const cached = findNanodictatePaths((await findCaches()).stdout);
      const failed: string[] = [];
      for (const file of cached) {
        const res = await deps.runFn("/bin/rm", ["-rf", file]);
        if (res.status !== 0) failed.push(file);
      }
      return {
        ok: failed.length === 0,
        detail:
          failed.length === 0
            ? `removed ${cached.length} cached file(s)`
            : `failed to remove: ${failed.join(", ")}`,
      };
    },
    verify: async () => findNanodictatePaths((await findCaches()).stdout).length === 0,
  });

  // 4. MacPorts (only when macports itself is installed)
  const portInstalledProbe = async (): Promise<RunResult> =>
    deps.runFn("sudo", ["-n", MACPORTS_PORT_BIN, "installed", "nanodictate"]);
  await record({
    id: "macportsPort",
    label: "MacPorts port nanodictate",
    probe: async () => {
      if (!deps.existsFn(MACPORTS_PORT_BIN)) {
        return { found: false, detail: "macports not installed (/opt/local/bin/port absent) — skipped" };
      }
      const res = await portInstalledProbe();
      const text = res.stdout + res.stderr;
      const found = matchPortInstalled(text);
      return {
        found,
        detail: found
          ? tail(text, 3)
          : `no nanodictate port (exit ${res.status}): ${tail(text, 2) || "no output"}`,
      };
    },
    act: async () => {
      const uninstall = await deps.runFn("sudo", [
        "-n",
        MACPORTS_PORT_BIN,
        "uninstall",
        "nanodictate",
      ]);
      const clean = await deps.runFn("sudo", ["-n", MACPORTS_PORT_BIN, "clean", "--all"]);
      return {
        ok: uninstall.status === 0,
        detail: `port uninstall → exit ${uninstall.status}; port clean --all → exit ${clean.status}`,
      };
    },
    verify: async () => {
      const res = await portInstalledProbe();
      return !matchPortInstalled(res.stdout + res.stderr);
    },
  });

  // 5. LaunchAgent loaded in launchd
  const agentService = `gui/${deps.uid}/${AGENT_SERVICE_NAME}`;
  const launchPrint = () => deps.runFn("/bin/launchctl", ["print", agentService]);
  await record({
    id: "launchAgentLoaded",
    label: `launchd service ${agentService}`,
    probe: async () => {
      const res = await launchPrint();
      return {
        found: res.status === 0,
        detail: res.status === 0 ? "service is loaded" : `launchctl print exit ${res.status}`,
      };
    },
    act: async () => {
      const res = await deps.runFn("/bin/launchctl", ["bootout", agentService]);
      const alreadyGone = /no such process|not found|could not find service/i.test(res.stderr);
      return {
        ok: res.status === 0 || alreadyGone,
        detail: `launchctl bootout → exit ${res.status}${res.stderr.trim() ? `: ${tail(res.stderr, 2)}` : ""}`,
      };
    },
    verify: async () => (await launchPrint()).status !== 0,
  });

  // 6. User LaunchAgent plist
  await record(rmItem(paths.userPlist, "userPlist", `User LaunchAgent plist ${paths.userPlist}`, "-f"));

  // 7. Root LaunchAgent plist (never removed non-interactively)
  await record({
    id: "rootPlist",
    label: `Root LaunchAgent plist ${paths.rootPlist}`,
    probe: async () => ({ found: deps.existsFn(paths.rootPlist) }),
    manualCommand: `sudo rm -f ${paths.rootPlist}`,
  });

  // 8. Config directory
  await record(rmItem(paths.configDir, "configDir", `Config directory ${paths.configDir}`, "-rf"));

  // 9. User logs
  await record(rmItem(paths.userLogsDir, "userLogs", `User logs ${paths.userLogsDir}`, "-rf"));

  // 10. Root logs (never removed non-interactively)
  await record({
    id: "rootLogs",
    label: `Root logs ${paths.rootLogsDir}`,
    probe: async () => ({ found: deps.existsFn(paths.rootLogsDir) }),
    manualCommand: `sudo rm -rf ${paths.rootLogsDir}`,
  });

  // 11. Stray dotfiles in $HOME. The `*` glob is expanded IN-PROCESS because
  // spawn() runs without a shell: `ls -d <home>/.nanodictate*` would hand the
  // literal `*` to ls (which does no globbing) and find nothing. List the home
  // directory instead and keep only paths under the `.nanodictate` prefix.
  const dotfilePrefix = `${deps.home}/.nanodictate`;
  const listDotfiles = async (): Promise<string[]> => {
    const res = await deps.runFn("/bin/ls", ["-A", deps.home]);
    if (res.status !== 0) return [];
    return res.stdout
      .split("\n")
      .map((name) => name.trim())
      .filter((name) => name.length > 0)
      .map((name) => join(deps.home, name))
      .filter((path) => path.startsWith(dotfilePrefix));
  };
  await record({
    id: "homeDotfiles",
    label: `Stray files ${dotfilePrefix}*`,
    probe: async () => {
      const found = await listDotfiles();
      return {
        found: found.length > 0,
        detail: found.length ? found.join(", ") : "none",
      };
    },
    act: async () => {
      const found = await listDotfiles();
      const failed: string[] = [];
      for (const file of found) {
        const res = await deps.runFn("/bin/rm", ["-rf", file]);
        if (res.status !== 0) failed.push(file);
      }
      return {
        ok: failed.length === 0,
        detail: failed.length ? `failed to remove: ${failed.join(", ")}` : `removed ${found.length} path(s)`,
      };
    },
    verify: async () => (await listDotfiles()).length === 0,
  });

  // 12. /usr/local/bin/nanodictate symlink
  await record(rmItem(paths.symlink, "symlink", `CLI symlink ${paths.symlink}`, "-f"));

  // 13. Accessibility cooldown stamp — lives in the preferences store, NOT in
  // the plist, so it must be deleted explicitly (cfprefsd keeps it cached).
  await record({
    id: "accessibilityStamp",
    label: `Accessibility cooldown stamp ${AGENT_BUNDLE_ID} ${ACCESSIBILITY_STAMP_KEY}`,
    probe: async () => {
      const res = await deps.runFn("defaults", ["read", AGENT_BUNDLE_ID, ACCESSIBILITY_STAMP_KEY]);
      return {
        found: res.status === 0,
        detail: res.status === 0 ? res.stdout.trim() : "stamp not set",
      };
    },
    act: async () => {
      const res = await deps.runFn("defaults", ["delete", AGENT_BUNDLE_ID, ACCESSIBILITY_STAMP_KEY]);
      const absent = /does not exist|not find|No such/i.test(res.stderr);
      return {
        ok: res.status === 0 || absent,
        detail: `defaults delete → exit ${res.status}${absent ? " (was already absent — ok)" : ""}`,
      };
    },
    verify: async () =>
      (await deps.runFn("defaults", ["read", AGENT_BUNDLE_ID, ACCESSIBILITY_STAMP_KEY])).status !== 0,
  });

  // 14. TCC Accessibility/Microphone grants — Accessibility in the system
  // TCC.db, Microphone in the per-user one. Both are unreadable to the agent
  // (SIP + interactive sudo; even `ls` of the parent directories is refused,
  // and the system db additionally needs Full Disk Access), so this step is
  // ALWAYS manual and is never probed or acted: the exact sudo commands are
  // handed to the user instead, labelled so they stand out from the root-file
  // commands. Two commands are emitted — a read-only CHECK (SELECT, first: see
  // what is recorded before erasing) and the ERASE (DELETE, second), each
  // behind its own label so the block stays copy-pasteable; both commands run
  // against BOTH databases. Presence cannot be checked, hence the item is
  // reported unconditionally and is excluded from readiness.
  items.push({
    id: TCC_RECORDS_STEP_ID,
    label: "TCC records (Accessibility/Microphone grants) in system + per-user TCC.db",
    status: "manual-sudo",
    detail:
      "agent cannot read TCC.db (system + per-user; SIP + interactive sudo, system db needs Full Disk Access) — run the exact sudo commands in Terminal (check first, then erase); the DELETE is a no-op if no records exist",
    command: TCC_GRANTS_DELETE_CMD,
  });
  manualCommands.push(TCC_GRANTS_CHECK_LABEL);
  manualCommands.push(TCC_GRANTS_SELECT_CMD);
  manualCommands.push(TCC_GRANTS_LABEL);
  manualCommands.push(TCC_GRANTS_DELETE_CMD);

  // 15. Agent processes — pkill only after the uninstall/bootout steps above.
  const pgrep = async () => {
    const res = await deps.runFn("/usr/bin/pgrep", ["-f", "NanoDictateAgent"]);
    return parsePgrep(res.stdout);
  };
  const pidsAtStart = await pgrep();
  let pidsAfter: number[] = pidsAtStart;

  if (pidsAtStart.length === 0) {
    items.push({
      id: "agentProcesses",
      label: "NanoDictateAgent processes",
      status: "clean",
      detail: "no process running",
      command: null,
    });
  } else if (dryRun) {
    items.push({
      id: "agentProcesses",
      label: "NanoDictateAgent processes",
      status: "dryrun",
      detail: `pids ${pidsAtStart.join(", ")} running — would pkill (dry run: nothing was executed).`,
      command: null,
    });
  } else {
    const stillRunning = await pgrep();
    let killExit = 0;
    if (stillRunning.length > 0) {
      killExit = (await deps.runFn("/usr/bin/pkill", ["-f", "NanoDictateAgent"])).status;
    }
    pidsAfter = await pgrep();
    items.push({
      id: "agentProcesses",
      label: "NanoDictateAgent processes",
      status: pidsAfter.length === 0 ? "wiped" : "failed",
      detail: `pids before ${pidsAtStart.join(", ")}; pkill exit ${killExit}; remaining ${pidsAfter.length ? pidsAfter.join(", ") : "none"}`,
      command: null,
    });
    if (pidsAfter.length > 0) leftover.push("agentProcesses");
  }

  // newcomer readiness reflects the FILE-based positions only: the TCC step is
  // always manual (the agent cannot read TCC.db), so it must never flip a
  // file-clean machine to "not ready".
  const fileItems = items.filter((i) => i.id !== TCC_RECORDS_STEP_ID);
  const everyItemClean = fileItems.every(
    (i) => i.status === "clean" || i.status === "wiped",
  );
  const processesLeft = dryRun ? pidsAtStart : pidsAfter;
  const newcomerReady = everyItemClean && processesLeft.length === 0;

  const baseDetail = newcomerReady
    ? dryRun
      ? "dry run: machine is already clean — a real wipe would delete nothing."
      : "wipe complete: no nanodictate traces left, machine is newcomer-ready."
    : dryRun
      ? `dry run: ${fileItems.filter((i) => i.status === "dryrun" || i.status === "manual-sudo").length} trace(s) would be removed — rerun with dry_run=false to clean.`
      : `wipe incomplete — leftover: ${leftover.join(", ") || "none"}; manual commands required: ${manualCommands.length}.`;

  return {
    success: newcomerReady,
    dryRun,
    items,
    newcomerReady,
    manualCommands,
    leftover,
    pidsAfter,
    detail: `${baseDetail}\n${TCC_MANUAL_NOTE}`,
  };
}

// ── CI signing certificate (dictation_cert_*) ───────────────────────────────

export interface GithubSecretsProbe {
  status: "present" | "absent" | "unreachable";
  detail: string;
}

export interface CertStatusResult {
  success: boolean;
  identities: IdentityEntry[];
  ciSigningPresent: boolean;
  devIdentityPresent: boolean;
  /** true when a local codesign with "NanoDictate CI Signing" is possible. */
  usableLocal: boolean;
  githubSecrets: GithubSecretsProbe;
  detail: string;
}

export interface CertEnsureResult {
  success: boolean;
  action: "exists" | "created" | "error";
  ciSigningPresent: boolean;
  identities: IdentityEntry[];
  warnings: string[];
  detail: string;
}

export interface CertPublishResult {
  success: boolean;
  executed: boolean;
  secretsState: "present" | "absent" | "unreachable";
  localCertPresent: boolean;
  /** 0600 file holding the base64 p12 — the material itself never leaves it. */
  materialPath: string | null;
  /** 0600 file holding the p12 password — the value itself never leaves it. */
  passwordPath: string | null;
  instructions: string[];
  detail: string;
}

/**
 * Mirrors the certificate recipe used by .github/workflows/release.yml:
 * self-signed RSA-2048 X.509 with the codeSigning extended key usage, exported
 * as a password-protected p12. certtool cannot express the codeSigning EKU and
 * the system openssl is LibreSSL without -addext, so the generation goes
 * through python3 + cryptography (present on macOS CLT hosts).
 */
const CI_P12_GENERATOR_SCRIPT = `import datetime
import sys

from cryptography import x509
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives.serialization import pkcs12
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID

common_name, password, out_path = sys.argv[1], sys.argv[2], sys.argv[3]

key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, common_name)])
now = datetime.datetime.now(datetime.timezone.utc)

cert = (
    x509.CertificateBuilder()
    .subject_name(name)
    .issuer_name(name)
    .public_key(key.public_key())
    .serial_number(x509.random_serial_number())
    .not_valid_before(now - datetime.timedelta(days=1))
    .not_valid_after(now + datetime.timedelta(days=3650))
    .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
    .add_extension(
        x509.KeyUsage(
            digital_signature=True,
            content_commitment=False,
            key_encipherment=False,
            data_encipherment=False,
            key_agreement=False,
            key_cert_sign=False,
            crl_sign=False,
            encipher_only=None,
            decipher_only=None,
        ),
        critical=True,
    )
    .add_extension(
        x509.ExtendedKeyUsage([ExtendedKeyUsageOID.CODE_SIGNING]), critical=False
    )
    .sign(key, hashes.SHA256())
)

blob = pkcs12.serialize_key_and_certificates(
    common_name.encode("utf-8"), key, cert, None, password.encode("utf-8")
)
with open(out_path, "wb") as handle:
    handle.write(blob)
print("wrote " + out_path)
`;

/**
 * Reads a p12 back (key + certificates) and prints the certificate names so
 * the caller can prove the export contains exactly the CI identity — never the
 * maintainer's dev identity.
 */
const P12_VERIFY_SCRIPT = `import sys

from cryptography.hazmat.primitives.serialization import pkcs12

p12_path, password = sys.argv[1], sys.argv[2]
with open(p12_path, "rb") as handle:
    blob = handle.read()
key, cert, cas = pkcs12.load_key_and_certificates(blob, password.encode("utf-8"))
names = []
if cert is not None:
    names.append(cert.subject.rfc4514_string())
for extra in cas or []:
    names.append(extra.subject.rfc4514_string())
if key is None:
    print("NO_PRIVATE_KEY")
    sys.exit(3)
print("|".join(names))
`;

/** Probe GitHub for the CI signing secrets. Never throws. */
async function probeGithubSecrets(deps: CommandDeps): Promise<GithubSecretsProbe> {
  const res = await deps.runFn("gh", ["secret", "list"], {
    cwd: PROJECT_ROOT,
    timeoutMs: COMMAND_TIMEOUT_MS,
  });
  if (res.status !== 0) {
    return {
      status: "unreachable",
      detail:
        tail(res.stderr + res.stdout, 3) ||
        `gh secret list exited ${res.status} — cannot confirm whether the secrets exist`,
    };
  }
  const hasP12 = res.stdout.includes(CI_P12_SECRET);
  const hasPassword = res.stdout.includes(CI_P12_PASSWORD_SECRET);
  if (hasP12 && hasPassword) {
    return { status: "present", detail: `${CI_P12_SECRET} + ${CI_P12_PASSWORD_SECRET} are configured` };
  }
  if (!hasP12 && !hasPassword) {
    return { status: "absent", detail: "neither CI signing secret is configured" };
  }
  return {
    status: "absent",
    detail: `partial configuration: ${hasP12 ? CI_P12_PASSWORD_SECRET : CI_P12_SECRET} is missing`,
  };
}

/** Local keychain view + best-effort GitHub secrets view. Read-only. */
export async function getCertStatus(
  depsIn?: Partial<CommandDeps>,
): Promise<CertStatusResult> {
  const deps = await resolveCommandDeps(depsIn);
  const identities = await listCodeSigningIdentities(deps);
  const ciSigningPresent = identities.some((i) => i.name === CI_SIGNING_IDENTITY);
  const devIdentityPresent = identities.some((i) => i.name === SIGNING_IDENTITY);
  const githubSecrets = await probeGithubSecrets(deps);

  return {
    success: true,
    identities,
    ciSigningPresent,
    devIdentityPresent,
    usableLocal: ciSigningPresent,
    githubSecrets,
    detail: ciSigningPresent
      ? `"${CI_SIGNING_IDENTITY}" is available locally — codesign can use it without touching GitHub.`
      : `"${CI_SIGNING_IDENTITY}" is NOT in the local keychain — run dictation_cert_ensure to create it (the dev identity "${SIGNING_IDENTITY}" is ${devIdentityPresent ? "present" : "absent"}).`,
  };
}

/**
 * Create the local CI identity, mirroring the GitHub recipe. Never overwrites:
 * if an identity named "NanoDictate CI Signing" already exists this is a no-op.
 * The dev identity (SIGNING_IDENTITY) is never touched.
 */
export async function ensureCiSigningIdentity(
  depsIn?: Partial<CommandDeps>,
): Promise<CertEnsureResult> {
  const deps = await resolveCommandDeps(depsIn);
  const before = await listCodeSigningIdentities(deps);

  if (before.some((i) => i.name === CI_SIGNING_IDENTITY)) {
    return {
      success: true,
      action: "exists",
      ciSigningPresent: true,
      identities: before,
      warnings: [],
      detail: `"${CI_SIGNING_IDENTITY}" already exists in the keychain — nothing was created or overwritten.`,
    };
  }

  const tmp = mkdtempSync(join(tmpdir(), "nanodictate-cert-"));
  const scriptPath = join(tmp, "make_ci_p12.py");
  const p12Path = join(tmp, "ci-signing.p12");
  const p12Password = randomBytes(18).toString("base64url");
  const keychain = join(deps.home, "Library/Keychains/login.keychain-db");
  const warnings: string[] = [];

  try {
    writeFileSync(scriptPath, CI_P12_GENERATOR_SCRIPT, { mode: 0o600 });

    const generated = await deps.runFn(
      "/usr/bin/python3",
      [scriptPath, CI_SIGNING_IDENTITY, p12Password, p12Path],
      { timeoutMs: COMMAND_TIMEOUT_MS },
    );
    if (generated.status !== 0) {
      return {
        success: false,
        action: "error",
        ciSigningPresent: false,
        identities: before,
        warnings,
        detail: `certificate generation failed (exit ${generated.status}): ${tail(generated.stderr + generated.stdout, 5) || "no output"}`,
      };
    }

    const imported = await deps.runFn(
      "security",
      ["import", p12Path, "-k", keychain, "-P", p12Password, "-T", "/usr/bin/codesign"],
      { timeoutMs: COMMAND_TIMEOUT_MS },
    );
    if (imported.status !== 0) {
      return {
        success: false,
        action: "error",
        ciSigningPresent: false,
        identities: before,
        warnings,
        detail: `security import failed (exit ${imported.status}): ${tail(imported.stderr + imported.stdout, 5) || "no output"}`,
      };
    }

    // Without a partition list entry codesign cannot read the private key.
    // `-l` restricts the update to the freshly imported CI identity so the
    // partition list of unrelated keys in the keychain is left untouched.
    const partition = await deps.runFn(
      "security",
      [
        "set-key-partition-list",
        "-S",
        "apple-tool:,apple:",
        "-l",
        CI_SIGNING_IDENTITY,
        keychain,
      ],
      { timeoutMs: PARTITION_TIMEOUT_MS },
    );
    if (partition.status !== 0) {
      warnings.push(
        `set-key-partition-list did not complete non-interactively (exit ${partition.status}). ` +
          `If codesign cannot use the identity, run by hand: security set-key-partition-list -S apple-tool:,apple: -k <keychain-password> ${keychain}`,
      );
    }

    const after = await listCodeSigningIdentities(deps);
    const present = after.some((i) => i.name === CI_SIGNING_IDENTITY);
    if (!present) {
      return {
        success: false,
        action: "error",
        ciSigningPresent: false,
        identities: after,
        warnings,
        detail: `import reported success but "${CI_SIGNING_IDENTITY}" is not visible in \`security find-identity\`.`,
      };
    }

    return {
      success: true,
      action: "created",
      ciSigningPresent: true,
      identities: after,
      warnings,
      detail:
        `Created self-signed RSA-2048 codeSigning certificate "${CI_SIGNING_IDENTITY}" (same shape as the GitHub CI identity) and imported it into ${keychain}. ` +
        `The existing "${SIGNING_IDENTITY}" identity was not touched.`,
    };
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
}

interface P12Export {
  ok: boolean;
  p12Base64?: string;
  password?: string;
  error?: string;
}

/**
 * Persist the exported p12 material to 0600 files so the secrets never travel
 * through a tool result or a renderer — only the paths are returned.
 *
 * The directory is a fresh `mktemp`-style dir under the OS tmpdir, created
 * with 0700 by mkdtempSync. It deliberately OUTLIVES this call: the operator
 * must be able to run the `gh secret set ... < file` commands afterwards, so
 * nothing here removes it. Only a successful automated publish deletes the
 * directory (see publishCiSigningToGithub); a prepared/unreachable/failed
 * publish leaves the files in place for the manual path.
 */
function writePublishMaterial(
  p12Base64: string,
  password: string,
): { dir: string; materialPath: string; passwordPath: string } {
  const dir = mkdtempSync(join(tmpdir(), "nanodictate-cert-publish-"));
  const materialPath = join(dir, "nanodictate-signing.p12.b64");
  const passwordPath = join(dir, "nanodictate-signing-password.txt");
  writeFileSync(materialPath, p12Base64, { mode: 0o600 });
  writeFileSync(passwordPath, password, { mode: 0o600 });
  return { dir, materialPath, passwordPath };
}

/** Verify a p12 contains only the CI identity; returns an error when foreign. */
async function verifyExportedP12(
  deps: CommandDeps,
  p12Path: string,
  password: string,
): Promise<{ ok: true; names: string[] } | { ok: false; error: string }> {
  const tmp = mkdtempSync(join(tmpdir(), "nanodictate-cert-verify-"));
  const scriptPath = join(tmp, "verify_p12.py");
  try {
    writeFileSync(scriptPath, P12_VERIFY_SCRIPT, { mode: 0o600 });
    const res = await deps.runFn(
      "/usr/bin/python3",
      [scriptPath, p12Path, password],
      { timeoutMs: COMMAND_TIMEOUT_MS },
    );
    if (res.status !== 0) {
      return {
        ok: false,
        error: `p12 verification failed (exit ${res.status}): ${tail(res.stderr + res.stdout, 4) || "no output"}`,
      };
    }
    const names = res.stdout
      .trim()
      .split("|")
      .map((s) => s.trim())
      .filter((s) => s.length > 0);
    if (names.length === 0) {
      return { ok: false, error: "p12 verification returned no certificate names" };
    }
    const foreign = names.filter((n) => !n.includes(CI_SIGNING_IDENTITY));
    if (foreign.length > 0) {
      return {
        ok: false,
        error: `exported p12 also contains ${foreign.join(", ")} — refusing to publish anything but "${CI_SIGNING_IDENTITY}".`,
      };
    }
    return { ok: true, names };
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
}

/** Export the local CI identity as a password-protected base64 p12. */
async function exportCiP12(deps: CommandDeps): Promise<P12Export> {
  const tmp = mkdtempSync(join(tmpdir(), "nanodictate-cert-export-"));
  const outPath = join(tmp, "ci-signing.p12");
  const password = randomBytes(18).toString("base64url");
  const keychain = join(deps.home, "Library/Keychains/login.keychain-db");

  try {
    const res = await deps.runFn(
      "security",
      [
        "export",
        "-k",
        keychain,
        "-t",
        "identities",
        "-f",
        "pkcs12",
        "-P",
        password,
        "-o",
        outPath,
        CI_SIGNING_IDENTITY,
      ],
      { timeoutMs: COMMAND_TIMEOUT_MS },
    );
    if (res.status !== 0) {
      return {
        ok: false,
        error: `security export failed (exit ${res.status}): ${tail(res.stderr + res.stdout, 4) || "no output"}`,
      };
    }
    if (!existsSync(outPath)) {
      return {
        ok: false,
        error: `security export reported success but wrote no file at ${outPath}`,
      };
    }
    const verdict = await verifyExportedP12(deps, outPath, password);
    if (!verdict.ok) return { ok: false, error: verdict.error };
    return { ok: true, p12Base64: readFileSync(outPath).toString("base64"), password };
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
}

export interface CertPublishOptions {
  /** false (default) = prepare the material and commands, send nothing. */
  execute?: boolean;
  deps?: Partial<CommandDeps>;
}

/**
 * Publish the local CI identity into the GitHub secrets the release workflow
 * reads. Never overwrites: if the secrets exist, or their state cannot be
 * confirmed, nothing is written. With execute=false this only prepares the
 * p12 material (0600 files) + the exact `gh secret set ... < file` commands.
 * The material itself never appears in the returned result — only the paths.
 */
export async function publishCiSigningToGithub(
  opts: CertPublishOptions = {},
): Promise<CertPublishResult> {
  const execute = opts.execute ?? false;
  const deps = await resolveCommandDeps(opts.deps);
  const identities = await listCodeSigningIdentities(deps);
  const localCertPresent = identities.some((i) => i.name === CI_SIGNING_IDENTITY);

  if (!localCertPresent) {
    return {
      success: false,
      executed: false,
      secretsState: "unreachable",
      localCertPresent: false,
      materialPath: null,
      passwordPath: null,
      instructions: ["Run dictation_cert_ensure first to create the local CI identity."],
      detail: `No "${CI_SIGNING_IDENTITY}" identity in the local keychain — nothing to publish.`,
    };
  }

  const gh = await probeGithubSecrets(deps);

  if (gh.status === "present") {
    return {
      success: false,
      executed: false,
      secretsState: "present",
      localCertPresent: true,
      materialPath: null,
      passwordPath: null,
      instructions: [],
      detail: `${CI_P12_SECRET} / ${CI_P12_PASSWORD_SECRET} already exist on GitHub (${gh.detail}) — refusing to overwrite them. Run \`gh secret list\` yourself if you really need to rotate.`,
    };
  }

  const exported = await exportCiP12(deps);
  if (!exported.ok) {
    return {
      success: false,
      executed: false,
      secretsState: gh.status,
      localCertPresent: true,
      materialPath: null,
      passwordPath: null,
      instructions: [],
      detail: exported.error ?? "p12 export failed",
    };
  }

  // The material and password now live only in 0600 files under a 0700 temp
  // dir that OUTLIVES this call — the operator needs them to run the
  // `gh secret set ... < file` commands. Nothing below ever embeds the values
  // in a result, detail, instruction or renderer.
  const material = writePublishMaterial(exported.p12Base64!, exported.password!);

  if (gh.status === "unreachable") {
    return {
      success: false,
      executed: false,
      secretsState: "unreachable",
      localCertPresent: true,
      materialPath: material.materialPath,
      passwordPath: material.passwordPath,
      instructions: [
        `gh secret list is unreachable (${gh.detail}) — absence of the secrets could not be confirmed, so nothing was written.`,
        `Check by hand: gh secret list --repo <owner>/<repo>`,
        `If ${CI_P12_SECRET} is absent, set it from the prepared files:`,
        `gh secret set ${CI_P12_SECRET} < ${material.materialPath}`,
        `gh secret set ${CI_P12_PASSWORD_SECRET} < ${material.passwordPath}`,
      ],
      detail: `GitHub unreachable — the p12 material is local only (0600 files under ${material.dir}); review the instructions before writing anything.`,
    };
  }

  const setCommands = [
    `gh secret set ${CI_P12_SECRET} < ${material.materialPath}`,
    `gh secret set ${CI_P12_PASSWORD_SECRET} < ${material.passwordPath}`,
  ];

  if (!execute) {
    return {
      success: true,
      executed: false,
      secretsState: "absent",
      localCertPresent: true,
      materialPath: material.materialPath,
      passwordPath: material.passwordPath,
      instructions: [
        `Secrets are absent on GitHub (${gh.detail}) — nothing was written (execute=false).`,
        "To install them yourself:",
        ...setCommands,
      ],
      detail: `Prepared only — the p12 material is in ${material.dir} (0600 files). Pass execute=true to write the two secrets, or run the commands above.`,
    };
  }

  // Secret values travel via stdin, never argv, so they don't leak into `ps`
  // output or error traces. gh reads the value from stdin when --body is
  // absent; the file content is read just before each write.
  const p12Result = await deps.runFn("gh", ["secret", "set", CI_P12_SECRET], {
    input: readFileSync(material.materialPath, "utf8"),
    cwd: PROJECT_ROOT,
    timeoutMs: COMMAND_TIMEOUT_MS,
  });
  const passwordResult = await deps.runFn(
    "gh",
    ["secret", "set", CI_P12_PASSWORD_SECRET],
    {
      input: readFileSync(material.passwordPath, "utf8"),
      cwd: PROJECT_ROOT,
      timeoutMs: COMMAND_TIMEOUT_MS,
    },
  );
  const ok = p12Result.status === 0 && passwordResult.status === 0;

  // On success the secrets are now owned by GitHub — drop the local 0600 files
  // and return null paths. Only a failed publish keeps the material in place
  // (the paths are returned) so the operator can run the documented commands.
  if (ok) {
    rmSync(material.dir, { recursive: true, force: true });
  }

  return {
    success: ok,
    executed: true,
    secretsState: "absent",
    localCertPresent: true,
    materialPath: ok ? null : material.materialPath,
    passwordPath: ok ? null : material.passwordPath,
    instructions: ok ? [] : setCommands,
    detail: ok
      ? `Installed ${CI_P12_SECRET} and ${CI_P12_PASSWORD_SECRET} on GitHub; local 0600 material removed.`
      : `gh secret set failed: ${CI_P12_SECRET} exit ${p12Result.status} (${tail(p12Result.stderr, 2)}); ` +
        `${CI_P12_PASSWORD_SECRET} exit ${passwordResult.status} (${tail(passwordResult.stderr, 2)}) — ` +
        `the prepared 0600 files are still at ${material.materialPath} / ${material.passwordPath}; run the documented commands to finish.`,
  };
}