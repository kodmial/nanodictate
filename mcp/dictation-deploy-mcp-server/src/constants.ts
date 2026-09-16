/**
 * Shared constants for the dictation-deploy MCP server.
 *
 * Layout:
 *   PROJECT_ROOT  the repo checkout (resolved from this file's location,
 *                  or overridden via the DICTATION_ROOT env var).
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
 * Resolved from this file's location (repo root → mcp → dictation-deploy-mcp-server → src),
 * or overridden via the DICTATION_ROOT environment variable when set.
 */
export const PROJECT_ROOT =
  process.env.DICTATION_ROOT ??
  resolve(fileURLToPath(new URL("../../..", import.meta.url)));

/**
 * Absolute path to the checkout this server is installed in. Three levels up
 * from dist/<file>.js (dist → dictation-deploy-mcp-server → mcp → checkout
 * root), which is the same number of levels from src/<file>.ts, so the
 * resolution works for both compiled and source layouts.
 */
export const SERVER_ROOT = fileURLToPath(new URL("../../..", import.meta.url));

// ── Signing identity ────────────────────────────────────────────────────────

/**
 * Stable code-signing identity (self-signed "Dictation Code Signing" certificate).
 *
 * The same identity + same entitlements → the SAME code directory hash (cdhash)
 * across rebuilds, so macOS keeps the Accessibility / Microphone TCC grants.
 */
export const SIGNING_IDENTITY = "Dictation Code Signing";

// ── Entitlements ────────────────────────────────────────────────────────────

/** Filename of DictatorAgent entitlements inside a checkout's Resources/. */
export const ENTITLEMENTS_AGENT_FILE = "com.dictation.agent.entitlements";

/** Filename of dictatorctl entitlements inside a checkout's Resources/. */
export const ENTITLEMENTS_DICTATORCTL_FILE = "com.dictation.dictatorctl.entitlements";

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

export const AGENT_BUNDLE_ID = "com.dictation.agent";
export const DICTATORCTL_BUNDLE_ID = "com.dictation.dictatorctl";

// ── LaunchAgent service ─────────────────────────────────────────────────────

export const AGENT_SERVICE_NAME = "com.dictation.agent";

// ── Build configuration ─────────────────────────────────────────────────────

export const CONFIGURATIONS = ["debug", "release"] as const;
export type Configuration = (typeof CONFIGURATIONS)[number];

/** Compute the absolute paths of built binaries for a given configuration. */
export function binaryPaths(configuration: Configuration) {
  const base = `${PROJECT_ROOT}/.build/${configuration}`;
  return {
    agent: `${base}/DictatorAgent`,
    dictatorctl: `${base}/dictatorctl`,
  };
}

// ── Timeouts / limits ───────────────────────────────────────────────────────

/** Timeout for `swift build` (a full package may take several minutes). */
export const BUILD_TIMEOUT_MS = 600_000; // 10 min

/** Timeout for short commands (codesign, launchctl, pgrep). */
export const COMMAND_TIMEOUT_MS = 60_000; // 1 min

/** Number of tail lines kept from build output. */
export const OUTPUT_TAIL_LINES = 40;