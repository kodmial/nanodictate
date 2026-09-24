/**
 * Unit tests for pure functions in src/constants.ts.
 *
 * Runs on node:test (node >= 22, no extra dependencies) against the compiled
 * dist/constants.js — `npm test` builds first.
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  PROJECT_ROOT,
  SERVER_ROOT,
  AGENT_BUNDLE_ID,
  NANODICTATE_BUNDLE_ID,
  TCC_GRANTS_DELETE_CMD,
  TCC_GRANTS_SELECT_CMD,
  TCC_SYSTEM_DB,
  TCC_UDIR_PREFIX,
  APP_BUNDLE_NAME,
  binaryPaths,
  defaultEntitlementRoots,
  resolveEntitlementsPath,
} from "../dist/constants.js";

// ── binaryPaths ─────────────────────────────────────────────────────────────

function expectedPaths(configuration) {
  const base = `${PROJECT_ROOT}/.build/${configuration}`;
  return {
    agent: `${base}/NanoDictateAgent`,
    nanodictate: `${base}/nanodictate`,
    appBundle: `${base}/${APP_BUNDLE_NAME}`,
  };
}

test("binaryPaths points into .build for debug and release", () => {
  assert.deepEqual(binaryPaths("debug"), expectedPaths("debug"));
  assert.deepEqual(binaryPaths("release"), expectedPaths("release"));
});

test("APP_BUNDLE_NAME is the packaging-layer .app bundle", () => {
  assert.equal(APP_BUNDLE_NAME, "NanoDictate.app");
});

test("defaultEntitlementRoots pairs the main checkout with SERVER_ROOT", () => {
  assert.deepEqual(defaultEntitlementRoots(), {
    mainCheckout: PROJECT_ROOT,
    worktree: SERVER_ROOT,
  });
});

// ── resolveEntitlementsPath ─────────────────────────────────────────────────

test("resolveEntitlementsPath prefers the main checkout, then the worktree", () => {
  const main = mkdtempSync(join(tmpdir(), "nanodictate-main-"));
  const worktree = mkdtempSync(join(tmpdir(), "nanodictate-wt-"));
  try {
    mkdirSync(join(main, "Resources"), { recursive: true });
    mkdirSync(join(worktree, "Resources"), { recursive: true });
    writeFileSync(join(main, "Resources", "only-main.entitlements"), "");
    writeFileSync(join(worktree, "Resources", "only-wt.entitlements"), "");
    const roots = { mainCheckout: main, worktree };

    assert.deepEqual(resolveEntitlementsPath("only-main.entitlements", roots), {
      path: join(main, "Resources", "only-main.entitlements"),
      source: "main-checkout",
    });
    assert.deepEqual(resolveEntitlementsPath("only-wt.entitlements", roots), {
      path: join(worktree, "Resources", "only-wt.entitlements"),
      source: "worktree",
    });
  } finally {
    rmSync(main, { recursive: true, force: true });
    rmSync(worktree, { recursive: true, force: true });
  }
});

test("resolveEntitlementsPath reports missing when neither checkout has the file", () => {
  const main = mkdtempSync(join(tmpdir(), "nanodictate-main-"));
  const worktree = mkdtempSync(join(tmpdir(), "nanodictate-wt-"));
  try {
    const res = resolveEntitlementsPath("absent.entitlements", {
      mainCheckout: main,
      worktree,
    });
    assert.equal(res.source, "missing");
    assert.equal(res.path, join(main, "Resources", "absent.entitlements"));
  } finally {
    rmSync(main, { recursive: true, force: true });
    rmSync(worktree, { recursive: true, force: true });
  }
});

test("resolveEntitlementsPath skips the worktree probe when worktree === mainCheckout", () => {
  const main = mkdtempSync(join(tmpdir(), "nanodictate-main-"));
  try {
    const res = resolveEntitlementsPath("x.entitlements", {
      mainCheckout: main,
      worktree: main,
    });
    assert.equal(res.source, "missing");
  } finally {
    rmSync(main, { recursive: true, force: true });
  }
});

// ── TCC manual commands ──────────────────────────────────────────────────────

test("TCC commands resolve the DB path via UDIR (console user), never via $HOME", () => {
  for (const cmd of [TCC_GRANTS_SELECT_CMD, TCC_GRANTS_DELETE_CMD]) {
    // $HOME must NOT be used as the path to the TCC.db (under sudo it is
    // /var/root — the cause of "unable to open database file").
    assert.equal(cmd.includes("$HOME/Library"), false, `no $HOME db path: ${cmd.slice(0, 40)}…`);
    // the canon prefix resolves the REAL console user's home and survives sudo
    assert.ok(cmd.startsWith(TCC_UDIR_PREFIX), "shares the UDIR prefix");
    assert.ok(cmd.includes('UDIR="$(dscl . -read'), "resolves home via dscl");
    assert.ok(cmd.includes("stat -f%Su /dev/console"), "console owner via stat");
    assert.ok(cmd.includes('UDIR="$HOME"'), "falls back to $HOME only when UDIR is empty");
    // the DB path is always the $UDIR suffix
    assert.ok(
      cmd.includes("$UDIR/Library/Application Support/com.apple.TCC/TCC.db"),
      "DB path is the $UDIR suffix",
    );
  }
});

test("TCC commands cover Accessibility and Microphone — SELECT queries both dbs, DELETE resets current ids via tccutil and sweeps the per-user db", () => {
  // the read-only CHECK still queries BOTH dbs — system (Accessibility) and
  // per-user (Microphone) — so neither grant can be silently missed
  assert.ok(
    TCC_GRANTS_SELECT_CMD.includes("/Library/Application Support/com.apple.TCC/TCC.db"),
    "SELECT targets the system db literal",
  );
  assert.ok(
    TCC_GRANTS_SELECT_CMD.includes("$UDIR/Library/Application Support/com.apple.TCC/TCC.db"),
    "SELECT targets the per-user db via $UDIR",
  );
  // the ERASE resets the CURRENT bundle ids for BOTH services via tccutil
  // (the official tool, which walks the SIP-protected system db itself)…
  assert.ok(
    TCC_GRANTS_DELETE_CMD.includes(`for id in ${AGENT_BUNDLE_ID} ${NANODICTATE_BUNDLE_ID}`),
    "DELETE resets the current bundle ids via tccutil",
  );
  assert.ok(
    TCC_GRANTS_DELETE_CMD.includes('tccutil reset Accessibility "$id"'),
    "DELETE resets the Accessibility service",
  );
  assert.ok(
    TCC_GRANTS_DELETE_CMD.includes('tccutil reset Microphone "$id"'),
    "DELETE resets the Microphone service",
  );
  // …and sweeps the per-user db with sqlite3 for the legacy names.
  assert.ok(
    TCC_GRANTS_DELETE_CMD.includes("$UDIR/Library/Application Support/com.apple.TCC/TCC.db"),
    "DELETE sweeps the per-user db via $UDIR",
  );
  // the DELETE must NOT open the system db with sqlite3: sudo alone is not
  // enough there (authorization denied without Full Disk Access), and a
  // rejected system delete used to be masked by the successful per-user one.
  assert.equal(
    TCC_GRANTS_DELETE_CMD.includes('sqlite3 "/Library'),
    false,
    "DELETE keeps the system db out of sqlite3",
  );
  assert.equal(TCC_SYSTEM_DB, "/Library/Application Support/com.apple.TCC/TCC.db");
  // the CHECK notes in its output that the system db needs Full Disk Access
  assert.match(TCC_GRANTS_SELECT_CMD, /Full Disk Access/);
});

test("TCC SQL clients are the hard-coded literals — no dynamic interpolation", () => {
  // the four fixed LIKE patterns; SELECT runs them against BOTH dbs → 8, the
  // DELETE's single sqlite3 statement (per-user db) → 4. Anything dynamic (a
  // client path, `"`, `$`, backtick) would shift the count and fail this lock.
  assert.equal(
    (TCC_GRANTS_SELECT_CMD.match(/LIKE '/g) ?? []).length,
    8,
    `four hard-coded LIKE literals per db × both dbs in: ${TCC_GRANTS_SELECT_CMD.slice(0, 60)}…`,
  );
  assert.equal(
    (TCC_GRANTS_DELETE_CMD.match(/LIKE '/g) ?? []).length,
    4,
    `four hard-coded LIKE literals in the DELETE's single per-user sqlite3 in: ${TCC_GRANTS_DELETE_CMD.slice(0, 60)}…`,
  );
});

test("TCC_GRANTS_DELETE_CMD erases only nanodictate-related client records", () => {
  assert.match(TCC_GRANTS_DELETE_CMD, /DELETE FROM access/);
  assert.match(TCC_GRANTS_DELETE_CMD, /client LIKE '%nanodictate%'/);
  assert.match(TCC_GRANTS_DELETE_CMD, /client LIKE '%com\.dictation\.agent%'/);
  assert.match(TCC_GRANTS_DELETE_CMD, /client LIKE '%DictatorAgent%'/);
  // the tccutil resets cover BOTH service grants for the current ids
  assert.match(TCC_GRANTS_DELETE_CMD, /set -e/);
  assert.match(TCC_GRANTS_DELETE_CMD, /done; echo "# legacy records \(per-user db, needs Full Disk Access\)"/);
});

test("TCC_GRANTS_SELECT_CMD is the read-only check (SELECT … FROM access)", () => {
  assert.match(TCC_GRANTS_SELECT_CMD, /SELECT service, client, auth_value,/);
  assert.match(TCC_GRANTS_SELECT_CMD, /FROM access/);
  assert.match(TCC_GRANTS_SELECT_CMD, /GROUP BY service, client, auth_value/);
  // read-only: no DELETE in the SELECT command
  assert.equal(TCC_GRANTS_SELECT_CMD.includes("DELETE FROM"), false);
});