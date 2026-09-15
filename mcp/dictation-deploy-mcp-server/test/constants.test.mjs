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
  binaryPaths,
  defaultEntitlementRoots,
  resolveEntitlementsPath,
} from "../dist/constants.js";

// ── binaryPaths ─────────────────────────────────────────────────────────────

function expectedPaths(configuration) {
  const base = `${PROJECT_ROOT}/.build/${configuration}`;
  return {
    agent: `${base}/DictatorAgent`,
    dictatorctl: `${base}/dictatorctl`,
  };
}

test("binaryPaths points into .build for debug and release", () => {
  assert.deepEqual(binaryPaths("debug"), expectedPaths("debug"));
  assert.deepEqual(binaryPaths("release"), expectedPaths("release"));
});

test("defaultEntitlementRoots pairs the main checkout with SERVER_ROOT", () => {
  assert.deepEqual(defaultEntitlementRoots(), {
    mainCheckout: PROJECT_ROOT,
    worktree: SERVER_ROOT,
  });
});

// ── resolveEntitlementsPath ─────────────────────────────────────────────────

test("resolveEntitlementsPath prefers the main checkout, then the worktree", () => {
  const main = mkdtempSync(join(tmpdir(), "dictation-main-"));
  const worktree = mkdtempSync(join(tmpdir(), "dictation-wt-"));
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
  const main = mkdtempSync(join(tmpdir(), "dictation-main-"));
  const worktree = mkdtempSync(join(tmpdir(), "dictation-wt-"));
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
  const main = mkdtempSync(join(tmpdir(), "dictation-main-"));
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