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
  mkdirSync,
  renameSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import {
  AGENT_BUNDLE_ID,
  AGENT_SERVICE_NAME,
  BUILD_TIMEOUT_MS,
  COMMAND_TIMEOUT_MS,
  NANODICTATE_BUNDLE_ID,
  ENTITLEMENTS_AGENT_FILE,
  ENTITLEMENTS_NANODICTATE_FILE,
  OUTPUT_TAIL_LINES,
  PROJECT_ROOT,
  SIGNING_IDENTITY,
  type Configuration,
  binaryPaths,
  resolveEntitlementsPath,
} from "./constants.js";

// ── Helpers ─────────────────────────────────────────────────────────────────

export interface RunResult {
  status: number;
  stdout: string;
  stderr: string;
}

interface RunOptions {
  cwd?: string;
  timeoutMs?: number;
  /** Extra environment variables merged over the inherited environment. */
  env?: Record<string, string | undefined>;
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
    const child = spawn(cmd, args, {
      cwd: opts.cwd,
      env: opts.env ? { ...process.env, ...opts.env } : undefined,
      stdio: ["ignore", "pipe", "pipe"],
    });

    let stdout = "";
    let stderr = "";
    let killedByTimeout = false;

    const timeoutMs = opts.timeoutMs ?? COMMAND_TIMEOUT_MS;
    const timer = setTimeout(() => {
      killedByTimeout = true;
      child.kill("SIGKILL");
    }, timeoutMs);

    child.stdout.on("data", (chunk: Buffer) => {
      stdout += chunk.toString();
    });
    child.stderr.on("data", (chunk: Buffer) => {
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
export async function checkSigningIdentity(): Promise<IdentityCheck> {
  const res = await run("security", [
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

async function signOneBinary(
  name: string,
  binaryPath: string,
  entitlementsPath: string,
  bundleId: string,
): Promise<SignBinaryResult> {
  if (!existsSync(binaryPath)) {
    return {
      name,
      path: binaryPath,
      signed: false,
      verified: false,
      detail: "binary not found — run dictation_build first",
    };
  }
  if (!existsSync(entitlementsPath)) {
    return {
      name,
      path: binaryPath,
      signed: false,
      verified: false,
      detail: `entitlements file missing: ${entitlementsPath}`,
    };
  }

  const signRes = await run(
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

  const verifyRes = await run(
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

// ── Sign project ────────────────────────────────────────────────────────────

export interface SignResult {
  success: boolean;
  configuration: Configuration;
  identity: string;
  binaries: SignBinaryResult[];
  detail: string;
}

/** Sign both NanoDictateAgent and nanodictate with the stable identity. */
export async function signProject(
  configuration: Configuration,
): Promise<SignResult> {
  const identity = await checkSigningIdentity();
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
  const [agentBin, ctlBin] = await Promise.all([
    signOneBinary(
      "NanoDictateAgent",
      paths.agent,
      agentEntitlements.path,
      AGENT_BUNDLE_ID,
    ),
    signOneBinary(
      "nanodictate",
      paths.nanodictate,
      ctlEntitlements.path,
      NANODICTATE_BUNDLE_ID,
    ),
  ]);

  const allSigned = agentBin.signed && ctlBin.signed;
  const allVerified = agentBin.verified && ctlBin.verified;
  const success = allSigned && allVerified;

  return {
    success,
    configuration,
    identity: SIGNING_IDENTITY,
    binaries: [agentBin, ctlBin],
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

/** Canonical LaunchAgent plist path (~/Library/LaunchAgents/com.nanodictate.agent.plist). */
function agentPlistPath(): string {
  return join(
    homedir(),
    "Library",
    "LaunchAgents",
    `${AGENT_SERVICE_NAME}.plist`,
  );
}

/** Agent log path used by the canonical plist. */
function agentLogPath(): string {
  return join(homedir(), "Library", "Logs", "NanoDictate", "agent.log");
}

/** XML-escape a plist string value (paths may contain &, ", <, >). */
function xmlEscape(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

/**
 * Inline XML of the canonical plist — mirrors AgentPlist.plistContent in
 * Sources/NanoDictateCore/AgentPlist.swift so the two writers stay in lockstep.
 */
function agentPlistContent(agentBinary: string, logPath: string): string {
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${AGENT_SERVICE_NAME}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${xmlEscape(agentBinary)}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${xmlEscape(logPath)}</string>
  <key>StandardErrorPath</key>
  <string>${xmlEscape(logPath)}</string>
</dict>
</plist>
`;
}

/**
 * Re-register the LaunchAgent so launchd's loaded plan points at the given
 * binary. Kickstart alone re-runs the STALE bootstrap-time plan (ProgramArguments
 * is read at bootstrap, not from the plist file) — a plist changed to a different
 * binary needs bootout → bootstrap to take effect. Failures are tolerated: when
 * the loaded plan already matches, the kickstart below succeeds regardless, and
 * a fully broken state is recovered by the `nanodictate start` fallback.
 */
async function reRegisterAgent(
  agentBinary: string,
  target: string,
): Promise<void> {
  const plistPath = agentPlistPath();
  try {
    mkdirSync(dirname(plistPath), { recursive: true });
    const tmpPath = `${plistPath}.tmp`;
    writeFileSync(tmpPath, agentPlistContent(agentBinary, agentLogPath()), {
      mode: 0o600,
    });
    renameSync(tmpPath, plistPath);
  } catch {
    return;
  }
  const domain = target.slice(0, target.lastIndexOf("/"));
  await run("/bin/launchctl", ["bootout", target]);
  await run("/bin/launchctl", ["bootstrap", domain, plistPath]);
}

/**
 * Restart the LaunchAgent via `launchctl kickstart -k`. Fallback to `nanodictate start`.
 * The agent is re-registered with .build/<configuration>/NanoDictateAgent first,
 * so a successful restart runs the freshly built and signed binary — never a
 * Homebrew/MacPorts install or an older build the plist used to point at.
 */
export async function restartAgent(
  configuration: Configuration = "debug",
): Promise<RestartResult> {
  const uid = (await run("id", ["-u"])).stdout.trim();
  const target = `gui/${uid}/${AGENT_SERVICE_NAME}`;

  const agentBinary = binaryPaths(configuration).agent;
  if (existsSync(agentBinary)) {
    await reRegisterAgent(agentBinary, target);
  }

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

/**
 * Expected agent entitlements — exactly what the canonical
 * Resources/com.nanodictate.agent.entitlements contains. Same identity + same
 * entitlements → same code-directory hash → TCC grants preserved across rebuilds.
 */
export const AGENT_ENTITLEMENTS: Record<string, unknown> = {
  "com.apple.security.device.audio-input": true,
};

/** True when the parsed entitlements match the expected agent set exactly. */
export function matchesAgentEntitlements(
  entitlements: Record<string, unknown> | null,
): boolean {
  if (!entitlements) return false;
  return (
    Object.keys(entitlements).length ===
      Object.keys(AGENT_ENTITLEMENTS).length &&
    Object.entries(AGENT_ENTITLEMENTS).every(
      ([key, value]) => entitlements[key] === value,
    )
  );
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
    codeSignature.identity === SIGNING_IDENTITY &&
    matchesAgentEntitlements(codeSignature.entitlements);

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