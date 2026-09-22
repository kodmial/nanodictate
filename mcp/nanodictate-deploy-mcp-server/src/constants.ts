/**
 * Shared constants for the nanodictate-deploy MCP server.
 *
 * Layout:
 *   PROJECT_ROOT  the repo checkout (resolved from this file's location,
 *                  or overridden via the NANODICTATE_ROOT env var).
 *     — `swift build` runs here; built binaries live in .build/{debug,release}.
 *   SERVER_ROOT   the checkout this server is running from
 *     — three levels up from dist/<file>.js or src/<file>.ts; after the
 *       feature branch merges it coincides with PROJECT_ROOT.
 *
 * The entitlements files live in each checkout's Resources/. They are consumed
 * through resolveEntitlementsPath(), which checks the main checkout first and
 * the server's own Resources/ second, so no absolute worktree path is baked
 * into the code and the lookup keeps working after the branch merges.
 */

import { existsSync } from "node:fs";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

// ── Project roots ────────────────────────────────────────────────────────────

/**
 * Absolute path to the main (non-worktree) git checkout of the dictation project.
 * Resolved from this file's location (repo root → mcp → nanodictate-deploy-mcp-server → src),
 * or overridden via the NANODICTATE_ROOT environment variable when set.
 */
export const PROJECT_ROOT =
  process.env.NANODICTATE_ROOT ??
  resolve(fileURLToPath(new URL("../../..", import.meta.url)));

/**
 * Absolute path to the checkout this server is installed in. Three levels up
 * from dist/<file>.js (dist → nanodictate-deploy-mcp-server → mcp → checkout
 * root), which is the same number of levels from src/<file>.ts, so the
 * resolution works for both compiled and source layouts.
 */
export const SERVER_ROOT = fileURLToPath(new URL("../../..", import.meta.url));

// ── Signing identity ────────────────────────────────────────────────────────

/**
 * Stable code-signing identity (self-signed "NanoDictate Code Signing" certificate).
 *
 * The same identity + same entitlements → the SAME code directory hash (cdhash)
 * across rebuilds, so macOS keeps the Accessibility / Microphone TCC grants.
 */
export const SIGNING_IDENTITY = "NanoDictate Code Signing";

// ── Entitlements ────────────────────────────────────────────────────────────

/** Filename of NanoDictateAgent entitlements inside a checkout's Resources/. */
export const ENTITLEMENTS_AGENT_FILE = "com.nanodictate.agent.entitlements";

/** Filename of nanodictate entitlements inside a checkout's Resources/. */
export const ENTITLEMENTS_NANODICTATE_FILE = "com.nanodictate.ctl.entitlements";

export interface EntitlementsResolution {
  /** Absolute path to the entitlements file (first candidate even when missing). */
  path: string;
  /** Which checkout provided it, or "missing" if neither has it. */
  source: "main-checkout" | "worktree" | "missing";
}

export interface EntitlementRoots {
  mainCheckout: string;
  worktree: string;
}

export function defaultEntitlementRoots(): EntitlementRoots {
  return { mainCheckout: PROJECT_ROOT, worktree: SERVER_ROOT };
}

/**
 * Locate an entitlements file: the main checkout's Resources/ first, then the
 * worktree's. Before the branch merges the files only exist in the worktree;
 * after the merge they land in the main checkout (and SERVER_ROOT equals
 * PROJECT_ROOT), so the lookup keeps working without constants edits.
 * The roots are injectable to keep the function pure for tests.
 */
export function resolveEntitlementsPath(
  name: string,
  roots: EntitlementRoots = defaultEntitlementRoots(),
): EntitlementsResolution {
  const primary = join(roots.mainCheckout, "Resources", name);
  if (existsSync(primary)) return { path: primary, source: "main-checkout" };

  if (roots.worktree !== roots.mainCheckout) {
    const secondary = join(roots.worktree, "Resources", name);
    if (existsSync(secondary)) return { path: secondary, source: "worktree" };
  }

  return { path: primary, source: "missing" };
}

// ── Bundle IDs (used in codesign --identifier) ──────────────────────────────

export const AGENT_BUNDLE_ID = "com.nanodictate.agent";
export const NANODICTATE_BUNDLE_ID = "com.nanodictate.ctl";

// ── LaunchAgent service ─────────────────────────────────────────────────────

export const AGENT_SERVICE_NAME = "com.nanodictate.agent";

// ── Build configuration ─────────────────────────────────────────────────────

/**
 * Name of the macOS .app bundle produced by the packaging layer (CI
 * release.yml / signed release). It carries BOTH binaries under
 * Contents/MacOS/ (NanoDictateAgent + nanodictate as siblings); a plain
 * `swift build` produces only the bare binaries and no bundle.
 */
export const APP_BUNDLE_NAME = "NanoDictate.app";

export const CONFIGURATIONS = ["debug", "release"] as const;
export type Configuration = (typeof CONFIGURATIONS)[number];

/** Compute the absolute paths of built binaries for a given configuration. */
export function binaryPaths(configuration: Configuration) {
  const base = `${PROJECT_ROOT}/.build/${configuration}`;
  return {
    agent: `${base}/NanoDictateAgent`,
    nanodictate: `${base}/nanodictate`,
    /** .app bundle — absent after a plain `swift build` (packaging-only). */
    appBundle: `${base}/${APP_BUNDLE_NAME}`,
  };
}

// ── Timeouts / limits ───────────────────────────────────────────────────────

/** Timeout for `swift build` (a full package may take several minutes). */
export const BUILD_TIMEOUT_MS = 600_000; // 10 min

/** Timeout for short commands (codesign, launchctl, pgrep). */
export const COMMAND_TIMEOUT_MS = 60_000; // 1 min

/** Number of tail lines kept from build output. */
export const OUTPUT_TAIL_LINES = 40;

// ── CI signing identity ─────────────────────────────────────────────────────

/**
 * CI signing identity used by .github/workflows/release.yml ("NanoDictate CI
 * Signing" — a self-signed RSA-2048 X.509 codeSigning certificate, material
 * stored only in GitHub secrets NANODICTATE_SIGNING_P12 / _PASSWORD).
 *
 * dictation_cert_* tools create/check this identity locally (mirroring the
 * GitHub recipe) so a local build signs with the same kind of certificate and
 * the local DR stays stable across rebuilds. The dev identity
 * (SIGNING_IDENTITY, "NanoDictate Code Signing") is never touched.
 */
export const CI_SIGNING_IDENTITY = "NanoDictate CI Signing";

/** GitHub secret holding the base64 p12 of the CI signing identity. */
export const CI_P12_SECRET = "NANODICTATE_SIGNING_P12";

/** GitHub secret holding the p12 password of the CI signing identity. */
export const CI_P12_PASSWORD_SECRET = "NANODICTATE_SIGNING_PASSWORD";

// ── Wipe targets (dictation_wipe) ───────────────────────────────────────────

export const NANODICTATE_TAP = "kodmial/homebrew-nanodictate";

/**
 * Local clone of the tap (brew untap removes it; rm -rf is the fallback).
 *
 * The clone lives under the Homebrew repository directory:
 * `$(brew --repository)/Library/Taps/kodmial/homebrew-nanodictate`. On Apple
 * Silicon HOMEBREW_REPOSITORY == HOMEBREW_PREFIX == /opt/homebrew — there is NO
 * nested /Homebrew segment there (that exists only in the Intel/Linux layout
 * /usr/local/Homebrew). wipeProject resolves the directory via
 * `brew --repository` at runtime; these constants are the arch fallback when
 * brew is absent or print nothing.
 */
export const NANODICTATE_TAP_CLONE_DIR_ARM =
  "/opt/homebrew/Library/Taps/kodmial/homebrew-nanodictate";

export const NANODICTATE_TAP_CLONE_DIR_INTEL =
  "/usr/local/Homebrew/Library/Taps/kodmial/homebrew-nanodictate";

/** Arch fallback for the tap clone when `brew --repository` cannot be run. */
export function tapCloneFallbackDir(arch: string = process.arch): string {
  return arch === "arm64"
    ? NANODICTATE_TAP_CLONE_DIR_ARM
    : NANODICTATE_TAP_CLONE_DIR_INTEL;
}

export const NANODICTATE_TAP_CLONE_DIR = tapCloneFallbackDir();

/** Tap clone directory under a resolved Homebrew repository dir. */
export function tapCloneDir(repository: string): string {
  return join(repository, "Library/Taps/kodmial/homebrew-nanodictate");
}

export const MACPORTS_PORT_BIN = "/opt/local/bin/port";

export const NANODICTATE_SYMLINK_PATH = "/usr/local/bin/nanodictate";

export const LAUNCH_AGENT_ROOT_PLIST =
  "/Library/LaunchAgents/com.nanodictate.agent.plist";

export const LOGS_DIR_ROOT = "/Library/Logs/NanoDictate";

/** Accessibility cooldown stamp domain key (survives plist removal — cfprefsd). */
export const ACCESSIBILITY_STAMP_KEY = "NanoDictate.lastAccessibilityPanelOpenAt";

/** Timeout for `security set-key-partition-list` — may prompt via GUI; keep short. */
export const PARTITION_TIMEOUT_MS = 15_000;

/**
 * Shared shell prefix for the TCC manual commands the USER runs in Terminal.
 *
 * Resolves the home directory of the REAL console user and survives `sudo`
 * (which resets $HOME to /var/root via env_reset). Canon path comes from
 * `dscl . -read "/Users/<console-owner>" NFSHomeDirectory` — the owner of
 * /dev/console is the logged-in user even while the shell runs as root; when
 * that resolution fails (headless/CI without a console) it falls back to
 * $HOME. Verified on macOS: `stat -f%Su /dev/console` → the console user,
 * `dscl` returns their /Users/<name> home, and the whole line parses under
 * both bash and zsh (sh-compatible copy-paste).
 */
export const TCC_UDIR_PREFIX =
  'UDIR="$(dscl . -read "/Users/$(stat -f%Su /dev/console 2>/dev/null)" NFSHomeDirectory 2>/dev/null | awk \'{print $2}\')"; [ -n "$UDIR" ] || UDIR="$HOME"';

/**
 * The SYSTEM-wide TCC database. SIP-guarded: even root cannot open it without
 * Full Disk Access — `sqlite3` then fails with "authorization denied", which
 * is why every TCC command touching it is delegated to the user and never
 * attempted by the agent. Holds the kTCCServiceAccessibility grants.
 */
export const TCC_SYSTEM_DB = "/Library/Application Support/com.apple.TCC/TCC.db";

/**
 * The per-user TCC database, "$UDIR/…" — resolved at run time by
 * TCC_UDIR_PREFIX (console-user home, NEVER $HOME: under sudo $HOME is
 * /var/root, the cause of "unable to open database file"). Holds
 * kTCCServiceMicrophone and the other user-scoped service grants. Appears in
 * the shell commands only as a double-quoted variable, so it never reaches a
 * SQL string — no client-controlled path is interpolated into a statement.
 */
export const TCC_USER_DB_PATH =
  "$UDIR/Library/Application Support/com.apple.TCC/TCC.db";

/**
 * SQL WHERE clause shared by the CHECK (SELECT) and ERASE (DELETE) statements.
 * Matches the current bundle ids com.nanodictate.agent / com.nanodictate.ctl
 * (both covered by the lowercase `%nanodictate%`) plus the former names
 * com.dictation.agent / DictatorAgent so leftovers from older installs are
 * caught too. Every literal is HARD-CODED — nothing user- or path-controlled
 * is interpolated into the SQL, so a value like /Users/o'brien/… can never
 * break a statement or leak into the shell.
 */
const TCC_CLIENTS_WHERE =
  "client LIKE '%nanodictate%' OR client LIKE '%NanoDictate%' OR client LIKE '%com.dictation.agent%' OR client LIKE '%DictatorAgent%'";

/**
 * Exact command the USER must run in Terminal to CHECK (read-only SELECT)
 * nanodictate's TCC grants. Both databases are queried — Accessibility lives
 * in the SYSTEM db (TCC_SYSTEM_DB), Microphone in the per-user db
 * (TCC_USER_DB_PATH) — so neither grant can be silently missed. Reading the
 * system db requires Full Disk Access (sudo alone is not enough); the echo
 * line that precedes it states that requirement in the output. The agent
 * cannot open these databases — SIP + interactive sudo denies even a read
 * (verified: `sqlite3` fails with "authorization denied", `ls` of the parent
 * directory is refused) — so dictation_wipe only PRINTS this command and
 * never attempts to touch TCC records itself. Pairs with
 * TCC_GRANTS_DELETE_CMD: run this first to see what would be erased.
 *
 * TRAP (caught 22-09-2026 on a real user): under `sudo` macOS resets $HOME to
 * /var/root (env_reset), so the old `"$HOME/Library/…/TCC.db"` resolved to
 * /var/root/Library/… and sqlite3 failed with "unable to open database file"
 * even though the real user db sits in /Users/<user>/Library/…. The canon is
 * therefore the TCC_UDIR_PREFIX (dscl/stat on the console user); $HOME is
 * only the fallback for a missing console. The per-user path is ALWAYS the
 * "$UDIR/…" suffix — never $HOME. `sudo` is kept on both queries for
 * uniformity with the DELETE (the whole block is one copy-paste): a
 * user-owner read usually works without it, but sudo costs nothing and avoids
 * permission surprises on restricted dbs. The `COUNT(*) c` column reports
 * duplicates (c > 1 = several records for the same service/client).
 */
export const TCC_GRANTS_SELECT_CMD =
  `${TCC_UDIR_PREFIX}; echo "# system TCC.db (Accessibility) — needs Full Disk Access"; sudo sqlite3 "${TCC_SYSTEM_DB}" "SELECT service, client, auth_value, COUNT(*) c FROM access WHERE ${TCC_CLIENTS_WHERE} GROUP BY service, client, auth_value;"; echo "# per-user TCC.db (Microphone)"; sudo sqlite3 "${TCC_USER_DB_PATH}" "SELECT service, client, auth_value, COUNT(*) c FROM access WHERE ${TCC_CLIENTS_WHERE} GROUP BY service, client, auth_value;";`;

/**
 * Exact command the USER must run in Terminal to erase nanodictate's TCC
 * grants — Accessibility from the SYSTEM db (TCC_SYSTEM_DB) and Microphone
 * from the per-user db (TCC_USER_DB_PATH). BOTH databases are targeted:
 * erasing only one would leave the other grant in place while the wipe output
 * claims both are gone. The system db requires Full Disk Access (sudo alone is
 * not enough — without it sqlite3 fails "authorization denied"), which is why
 * even this DELETE is always delegated to the user. The agent cannot open
 * these databases (SIP + interactive sudo) — dictation_wipe only PRINTS this
 * command and never attempts to delete TCC records itself (a no-op when no
 * matching records exist).
 *
 * The supported FDA-free alternative, `tccutil reset Accessibility|Microphone
 * <bundle-id>`, was evaluated and rejected here: tccutil matches EXACT bundle
 * ids only, so the legacy names com.dictation.agent / DictatorAgent covered by
 * the LIKE patterns below would be left behind. Shares the TCC_UDIR_PREFIX +
 * "$UDIR/…" path canon with TCC_GRANTS_SELECT_CMD (see the trap documented
 * there: $HOME under sudo is /var/root — the cause of "unable to open
 * database file"; the user db lives under the console user's home, never
 * under $HOME). Matches both the current bundle ids (com.nanodictate.agent /
 * com.nanodictate.ctl, covered by the lowercase `%nanodictate%`) and the
 * former names com.dictation.agent / DictatorAgent so leftovers from older
 * installs are caught too.
 */
export const TCC_GRANTS_DELETE_CMD =
  `${TCC_UDIR_PREFIX}; echo "# erase grant records from BOTH dbs — system (Accessibility) + user (Microphone); system db needs Full Disk Access"; sudo sqlite3 "${TCC_SYSTEM_DB}" "DELETE FROM access WHERE ${TCC_CLIENTS_WHERE};"; sudo sqlite3 "${TCC_USER_DB_PATH}" "DELETE FROM access WHERE ${TCC_CLIENTS_WHERE};";`;

export interface WipePaths {
  tapClone: string;
  userPlist: string;
  rootPlist: string;
  configDir: string;
  userLogsDir: string;
  rootLogsDir: string;
  downloadsCache: string;
  symlink: string;
}

/**
 * Absolute paths dictation_wipe probes/cleans. User-owned paths are computed
 * from the caller's home directory (injected by tests).
 */
export function wipePaths(home: string): WipePaths {
  return {
    tapClone: NANODICTATE_TAP_CLONE_DIR,
    userPlist: join(home, "Library/LaunchAgents/com.nanodictate.agent.plist"),
    rootPlist: LAUNCH_AGENT_ROOT_PLIST,
    configDir: join(home, ".config/nanodictate"),
    userLogsDir: join(home, "Library/Logs/NanoDictate"),
    rootLogsDir: LOGS_DIR_ROOT,
    downloadsCache: join(home, "Library/Caches/Homebrew/downloads"),
    symlink: NANODICTATE_SYMLINK_PATH,
  };
}