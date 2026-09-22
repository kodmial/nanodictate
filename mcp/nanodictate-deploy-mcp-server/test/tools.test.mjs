/**
 * Unit tests for the MCP tools layer in src/tools.ts.
 *
 * Runs on node:test (node >= 22, no extra dependencies) against the compiled
 * dist/tools.js — `npm test` builds first.
 *
 * Coverage notes (honest about what is and is not covered here):
 *
 *   Covered:
 *   - every Zod schema (input schemas parse/reject, defaults, strictness;
 *     output schemas accept the structuredContent contract and reject broken
 *     payloads),
 *   - the pure helpers (respond, render, and all five Markdown renderers),
 *   - registerTools (a fake McpServer records the five registrations: names,
 *     annotations, schema defaults, handler callbacks),
 *   - the safe handler paths: handleBuild / handleDeploy fail fast without
 *     spawning when SWIFT_TOOLCHAIN points at a non-existent toolchain
 *     (commands.buildProject returns before any `swift build` run), and
 *     handleStatus runs its read-only probes (id/pgrep/launchctl/codesign -dv)
 *     against the local machine — assertions check the result shape only, so
 *     they pass regardless of the machine state.
 *
 *   NOT unit-covered (spawn path — verified by the real-build verification,
 *   same stance as the commands.test.mjs header):
 *   - handleSign and handleRestart mutate the system (codesign --force on the
 *     real binaries / launchctl kickstart of the agent), so they are never
 *     invoked from tests,
 *   - the success branch of handleDeploy (sign/restart gating) is gated on a
 *     real `swift build` succeeding, which is out of scope for unit tests.
 */

import { afterEach, test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  BuildOutputSchema,
  BuildInputSchema,
  CONFIGURATION_SCHEMA,
  CONFIG_PARAM,
  CertEnsureInputSchema,
  CertEnsureOutputSchema,
  CertPublishInputSchema,
  CertPublishOutputSchema,
  CertStatusInputSchema,
  CertStatusOutputSchema,
  CodeSignatureSchema,
  DeployOutputSchema,
  DeployInputSchema,
  FORMAT_PARAM,
  RESPONSE_FORMAT_SCHEMA,
  RestartInputSchema,
  RestartOutputSchema,
  ResponseFormat,
  SignInputSchema,
  SignOutputSchema,
  StatusInputSchema,
  StatusOutputSchema,
  WipeInputSchema,
  WipeOutputSchema,
  buildMarkdown,
  certEnsureMarkdown,
  certPublishMarkdown,
  certStatusMarkdown,
  deployMarkdown,
  handleCertEnsure,
  handleCertPublish,
  handleCertStatus,
  handleWipe,
  registerTools,
  render,
  restartMarkdown,
  respond,
  signMarkdown,
  statusMarkdown,
  wipeMarkdown,
} from "../dist/tools.js";
import {
  CI_SIGNING_IDENTITY,
  SIGNING_IDENTITY,
  TCC_GRANTS_DELETE_CMD,
  TCC_GRANTS_SELECT_CMD,
} from "../dist/constants.js";
import { TCC_GRANTS_CHECK_LABEL, TCC_GRANTS_LABEL } from "../dist/commands.js";

// ── Shared input pieces ──────────────────────────────────────────────────────

test("CONFIGURATION_SCHEMA accepts debug/release and rejects others", () => {
  assert.equal(CONFIGURATION_SCHEMA.parse("debug"), "debug");
  assert.equal(CONFIGURATION_SCHEMA.parse("release"), "release");
  assert.equal(CONFIGURATION_SCHEMA.safeParse("Debug").success, false);
  assert.equal(CONFIGURATION_SCHEMA.safeParse("prod").success, false);
  assert.equal(CONFIGURATION_SCHEMA.safeParse(1).success, false);
});

test("CONFIG_PARAM defaults to debug", () => {
  assert.equal(CONFIG_PARAM.parse(undefined), "debug");
  assert.equal(CONFIG_PARAM.parse("release"), "release");
  assert.equal(CONFIG_PARAM.safeParse("Debug").success, false);
});

test("RESPONSE_FORMAT_SCHEMA accepts markdown/json and rejects others", () => {
  assert.equal(
    RESPONSE_FORMAT_SCHEMA.parse(ResponseFormat.MARKDOWN),
    ResponseFormat.MARKDOWN,
  );
  assert.equal(RESPONSE_FORMAT_SCHEMA.parse(ResponseFormat.JSON), ResponseFormat.JSON);
  assert.equal(RESPONSE_FORMAT_SCHEMA.safeParse("html").success, false);
});

test("FORMAT_PARAM defaults to markdown", () => {
  assert.equal(FORMAT_PARAM.parse(undefined), ResponseFormat.MARKDOWN);
  assert.equal(FORMAT_PARAM.parse(ResponseFormat.JSON), ResponseFormat.JSON);
});

// ── Input schemas (per tool) ────────────────────────────────────────────────

test("input schemas default configuration + response_format and are strict", () => {
  const withDefaults = [
    BuildInputSchema,
    SignInputSchema,
    StatusInputSchema,
    DeployInputSchema,
  ];
  for (const schema of withDefaults) {
    assert.deepEqual(schema.parse({}), {
      configuration: "debug",
      response_format: "markdown",
    });
  }
  assert.deepEqual(RestartInputSchema.parse({}), {
    response_format: "markdown",
  });
});

test("input schemas accept explicit values and reject unknown fields", () => {
  assert.deepEqual(
    BuildInputSchema.parse({ configuration: "release", response_format: "json" }),
    { configuration: "release", response_format: "json" },
  );
  assert.equal(
    BuildInputSchema.safeParse({ configuration: "prod" }).success,
    false,
  );
  assert.equal(BuildInputSchema.safeParse({ extra: true }).success, false);
  assert.equal(SignInputSchema.safeParse({ extra: true }).success, false);
  assert.equal(RestartInputSchema.safeParse({ extra: true }).success, false);
  assert.equal(StatusInputSchema.safeParse({ extra: true }).success, false);
  assert.equal(DeployInputSchema.safeParse({ extra: true }).success, false);
});

// ── Output schemas (structuredContent contract) ─────────────────────────────

test("SymlinkSchema contract is enforced through BuildOutputSchema", () => {
  const ok = BuildOutputSchema.safeParse({
    success: true,
    configuration: "debug",
    exitCode: 0,
    binaryPath: "/p/.build/debug/NanoDictateAgent",
    symlink: { created: true, target: "/p/bin/nanodictate", linkPath: "/usr/local/bin/nanodictate", detail: "ok" },
    tail: "Build complete",
  });
  assert.equal(ok.success, true);

  const badSymlink = BuildOutputSchema.safeParse({
    success: true,
    configuration: "debug",
    exitCode: 0,
    binaryPath: "/p/.build/debug/NanoDictateAgent",
    symlink: { created: "yes", target: 1, linkPath: 2, detail: 3 },
    tail: "",
  });
  assert.equal(badSymlink.success, false);
});

test("BuildOutputSchema rejects missing/extra fields and bad enum values", () => {
  const base = {
    configuration: "debug",
    exitCode: 0,
    binaryPath: "/p",
    symlink: { created: false, target: "/p", linkPath: "/u", detail: "d" },
    tail: "",
  };
  assert.equal(
    BuildOutputSchema.safeParse({ ...base, success: true }).success,
    true,
  );
  assert.equal(BuildOutputSchema.safeParse({ ...base }).success, false); // no success
  // output schemas are not .strict(): unknown keys are stripped, not rejected
  const stripped = BuildOutputSchema.parse({ ...base, success: true, extra: 1 });
  assert.equal("extra" in stripped, false);
  assert.equal(
    BuildOutputSchema.safeParse({ ...base, success: true, configuration: "prod" })
      .success,
    false,
  );
});

test("SignOutputSchema parses the sign result contract", () => {
  const bin = {
    name: "NanoDictateAgent",
    path: "/p/NanoDictateAgent",
    signed: true,
    verified: true,
    detail: "signed and verified",
  };
  assert.deepEqual(
    SignOutputSchema.parse({
      success: true,
      configuration: "release",
      identity: "NanoDictate Code Signing",
      binaries: [bin],
      detail: "All binaries signed and verified",
    }),
    {
      success: true,
      configuration: "release",
      identity: "NanoDictate Code Signing",
      binaries: [bin],
      detail: "All binaries signed and verified",
    },
  );
  assert.equal(
    SignOutputSchema.safeParse({
      success: true,
      configuration: "debug",
      identity: 42,
      binaries: [],
      detail: "",
    }).success,
    false,
  );
});

test("RestartOutputSchema parses the restart result contract", () => {
  assert.deepEqual(
    RestartOutputSchema.parse({
      success: true,
      method: "launchctl kickstart -k",
      detail: "Agent restarted",
    }),
    { success: true, method: "launchctl kickstart -k", detail: "Agent restarted" },
  );
  assert.equal(
    RestartOutputSchema.safeParse({ success: "yes", method: 1, detail: 2 }).success,
    false,
  );
});

test("CodeSignatureSchema and StatusOutputSchema parse the status contract", () => {
  const sig = {
    signed: true,
    identity: "NanoDictate Code Signing",
    teamId: null,
    entitlements: { "com.apple.security.device.audio-input": true },
    entitlementsFile: "/p/Resources/com.nanodictate.agent.entitlements",
  };
  assert.deepEqual(CodeSignatureSchema.parse(sig), sig);
  const status = {
    agentRunning: true,
    pids: [42],
    launchAgentLoaded: true,
    launchAgentDetail: "",
    binaryPath: "/p/NanoDictateAgent",
    codeSignature: sig,
    signatureStable: true,
  };
  assert.deepEqual(StatusOutputSchema.parse(status), status);
  // codeSignature is optional (null when binary missing)
  const noSig = StatusOutputSchema.parse({
    ...status,
    binaryPath: null,
    codeSignature: null,
    signatureStable: false,
  });
  assert.equal(noSig.binaryPath, null);
  assert.equal(noSig.codeSignature, null);
  assert.equal(noSig.signatureStable, false);
  assert.equal(
    StatusOutputSchema.safeParse({ ...status, agentRunning: "yes" }).success,
    false,
  );
});

test("DeployOutputSchema parses full and partial-gating contracts", () => {
  const full = {
    success: true,
    configuration: "debug",
    build: {
      success: true,
      exitCode: 0,
      binaryPath: "/p/NanoDictateAgent",
      tail: "done",
    },
    sign: {
      success: true,
      identity: "NanoDictate Code Signing",
      binaries: [],
    },
    restart: { success: true, method: "launchctl kickstart -k" },
    detail: "build → sign → restart OK",
  };
  assert.equal(DeployOutputSchema.safeParse(full).success, true);

  const buildFailed = {
    success: false,
    configuration: "debug",
    build: { success: false, exitCode: 1, binaryPath: "/p", tail: "" },
    sign: null,
    restart: null,
    detail: "build failed",
  };
  assert.equal(DeployOutputSchema.safeParse(buildFailed).success, true);
  assert.equal(
    DeployOutputSchema.safeParse({ ...full, success: "yes" }).success,
    false,
  );
});

// ── Response helpers ─────────────────────────────────────────────────────────

test("respond wraps text and structuredContent", () => {
  const r = respond("hello", { a: 1 });
  assert.deepEqual(r.content, [{ type: "text", text: "hello" }]);
  assert.deepEqual(r.structuredContent, { a: 1 });
});

test("render picks markdown or JSON by response_format", () => {
  const data = { a: [1, 2], b: "x" };
  assert.equal(render(ResponseFormat.MARKDOWN, "md text", data), "md text");
  assert.equal(render(ResponseFormat.JSON, "md text", data), JSON.stringify(data, null, 2));
});

// ── Markdown renderers ───────────────────────────────────────────────────────

test("buildMarkdown renders success and failure", () => {
  const ok = buildMarkdown({
    configuration: "debug",
    success: true,
    exitCode: 0,
    binaryPath: "/p/NanoDictateAgent",
    symlink: { created: true, target: "/p/nanodictate", linkPath: "/usr/local/bin/nanodictate", detail: "symlink created" },
    tail: "Build complete",
  });
  assert.match(ok, /# NanoDictate build/);
  assert.match(ok, /configuration: `debug`/);
  assert.match(ok, /status: \*\*OK\*\* \(exit 0\)/);
  assert.match(ok, /binary: `\/p\/NanoDictateAgent`/);
  assert.match(ok, /symlink: \*\*created\*\* — `symlink created`/);
  assert.match(ok, /Build complete/);

  const fail = buildMarkdown({
    configuration: "release",
    success: false,
    exitCode: 1,
    binaryPath: "/p/NanoDictateAgent",
    symlink: { created: false, target: "/p/nanodictate", linkPath: "/usr/local/bin/nanodictate", detail: "build failed — symlink not created" },
    tail: "error: boom",
  });
  assert.match(fail, /status: \*\*FAILED\*\* \(exit 1\)/);
  assert.match(fail, /binary: `\/p\/NanoDictateAgent` \(not created\)/);
  assert.match(fail, /symlink: NOT created/);
});

test("signMarkdown renders success, partial, and failure with detail", () => {
  const ok = signMarkdown({
    success: true,
    configuration: "debug",
    identity: "NanoDictate Code Signing",
    binaries: [
      { name: "NanoDictateAgent", path: "/p/a", signed: true, verified: true, detail: "signed and verified" },
      { name: "nanodictate", path: "/p/c", signed: true, verified: true, detail: "signed and verified" },
    ],
    detail: "All binaries signed and verified",
  });
  assert.match(ok, /# NanoDictate sign/);
  assert.match(ok, /overall: \*\*OK\*\*/);
  assert.match(ok, /NanoDictateAgent: \*\*signed\*\*, verified/);
  // default detail is elided from the line
  assert.equal(ok.includes("(signed and verified)"), false);

  const partial = signMarkdown({
    success: false,
    configuration: "debug",
    identity: "NanoDictate Code Signing",
    binaries: [
      { name: "NanoDictateAgent", path: "/p/a", signed: true, verified: false, detail: "signed but verify returned 1: nope" },
      { name: "nanodictate", path: "/p/c", signed: false, verified: false, detail: "binary not found" },
    ],
    detail: "Some binaries could not be signed or verified",
  });
  assert.match(partial, /overall: \*\*FAILED\*\*/);
  assert.match(partial, /signed\*\*, NOT verified/);
  assert.match(partial, /\*\*NOT signed\*\* \(binary not found\)/);
  assert.match(partial, /Some binaries could not be signed or verified/);
});

test("restartMarkdown renders success and failure", () => {
  const ok = restartMarkdown({
    success: true,
    method: "launchctl kickstart -k",
    detail: "Agent restarted via gui/501/com.nanodictate.agent",
  });
  assert.match(ok, /# NanoDictate agent restart/);
  assert.match(ok, /status: \*\*OK\*\*/);
  assert.match(ok, /method: `launchctl kickstart -k`/);

  const fail = restartMarkdown({
    success: false,
    method: "nanodictate start (fallback)",
    detail: "kickstart failed. Fallback: no output",
  });
  assert.match(fail, /status: \*\*FAILED\*\*/);
  assert.match(fail, /kickstart failed/);
});

test("statusMarkdown renders running-with-signature and not-built branches", () => {
  const sig = {
    signed: true,
    identity: "NanoDictate Code Signing",
    teamId: null,
    entitlements: { "com.apple.security.device.audio-input": true },
    entitlementsFile: "/p/Resources/com.nanodictate.agent.entitlements",
  };
  const running = statusMarkdown({
    agentRunning: true,
    pids: [42, 43],
    launchAgentLoaded: true,
    launchAgentDetail: "state = running",
    binaryPath: "/p/NanoDictateAgent",
    codeSignature: sig,
    signatureStable: true,
  });
  assert.match(running, /# NanoDictate agent status/);
  assert.match(running, /running: \*\*yes\*\*/);
  assert.match(running, /pids: 42, 43/);
  assert.match(running, /loaded: \*\*yes\*\*/);
  assert.match(running, /signed: \*\*yes\*\*/);
  assert.match(running, /stable signature \(identity = "NanoDictate Code Signing"\): \*\*yes\*\* — TCC grants preserved/);
  assert.match(running, /com\.apple\.security\.device\.audio-input = true/);
  assert.match(running, /state = running/);

  const withTeamId = statusMarkdown({
    agentRunning: false,
    pids: [],
    launchAgentLoaded: false,
    launchAgentDetail: "state = loaded",
    binaryPath: "/p/NanoDictateAgent",
    codeSignature: {
      ...sig,
      signed: false,
      identity: "Apple Development: x",
      teamId: "ABC123DE45",
      entitlements: null,
    },
    signatureStable: false,
  });
  assert.match(withTeamId, /running: \*\*no\*\*/);
  assert.match(withTeamId, /pids: \(none\)/);
  assert.match(withTeamId, /team id: `ABC123DE45`/);
  assert.match(withTeamId, /entitlements: \(none\)/);

  const notBuilt = statusMarkdown({
    agentRunning: false,
    pids: [],
    launchAgentLoaded: false,
    launchAgentDetail: "",
    binaryPath: null,
    codeSignature: null,
    signatureStable: false,
  });
  assert.match(notBuilt, /binary: \(not built\) — run `dictation_build` first/);
});

test("deployMarkdown renders success, binary lines, and gated failures", () => {
  const ok = deployMarkdown({
    configuration: "debug",
    success: true,
    build: {
      success: true,
      exitCode: 0,
      binaryPath: "/p/NanoDictateAgent",
      tail: "",
      symlink: { created: true },
    },
    sign: {
      success: true,
      identity: "NanoDictate Code Signing",
      binaries: [
        { name: "NanoDictateAgent", signed: true, verified: true },
        { name: "nanodictate", signed: true, verified: false },
      ],
    },
    restart: { success: true, method: "launchctl kickstart -k" },
    detail: "build → sign → restart OK",
  });
  assert.match(ok, /# NanoDictate deploy/);
  assert.match(ok, /overall: \*\*OK\*\*/);
  assert.match(ok, /## Build/);
  assert.match(ok, /\*\*OK\*\* \(exit 0\), binary `\/p\/NanoDictateAgent`, symlink created/);
  assert.match(ok, /NanoDictateAgent: signed, verified/);
  assert.match(ok, /nanodictate: signed/);
  assert.match(ok, /\*\*OK\*\* via `launchctl kickstart -k`/);

  const failed = deployMarkdown({
    configuration: "release",
    success: false,
    build: { success: false, exitCode: 1, binaryPath: "/p/NanoDictateAgent", tail: "", symlink: { created: false } },
    sign: null,
    restart: null,
    detail: "build failed",
  });
  assert.match(failed, /overall: \*\*FAILED\*\*/);
  assert.match(failed, /## Build/);
  assert.match(failed, /## Sign/);
  assert.match(failed, /- NOT RUN/);
  assert.match(failed, /detail: build failed/);

  const signFailed = deployMarkdown({
    configuration: "debug",
    success: false,
    build: {
      success: true,
      exitCode: 0,
      binaryPath: "/p/NanoDictateAgent",
      tail: "",
      symlink: { created: true },
    },
    sign: {
      success: false,
      identity: "NanoDictate Code Signing",
      binaries: [{ name: "NanoDictateAgent", signed: false, verified: false }],
      detail: "codesign failed (exit 1): identity not found",
    },
    restart: null,
    detail: "sign failed",
  });
  assert.match(signFailed, /- \*\*FAILED\*\* — identity `NanoDictate Code Signing`/);
  assert.match(signFailed, /NanoDictateAgent: NOT signed/);
  assert.match(signFailed, /codesign failed \(exit 1\)/);
  assert.match(signFailed, /- NOT RUN \(previous step failed\)/);
});

// ── registerTools ────────────────────────────────────────────────────────────

function makeFakeServer() {
  const registrations = [];
  return {
    registrations,
    registerTool(name, config, handler) {
      registrations.push({ name, config, handler });
    },
  };
}

test("registerTools registers all nine tools with schemas and annotations", () => {
  const server = makeFakeServer();
  registerTools(server);
  const byName = new Map(server.registrations.map((r) => [r.name, r]));

  assert.deepEqual(
    [...byName.keys()].sort(),
    [
      "dictation_build",
      "dictation_cert_ensure",
      "dictation_cert_publish_github",
      "dictation_cert_status",
      "dictation_deploy",
      "dictation_restart",
      "dictation_sign",
      "dictation_status",
      "dictation_wipe",
    ].sort(),
  );

  for (const [, r] of byName) {
    assert.equal(typeof r.config.inputSchema.safeParse, "function");
    assert.equal(typeof r.config.outputSchema.safeParse, "function");
    assert.equal(typeof r.handler, "function");
    assert.equal(typeof r.config.title, "string");
    assert.match(r.config.description, /./);
  }

  // input-schema defaults per tool (restart / cert_status / cert_ensure have no
  // configuration param; wipe defaults dry_run=true; publish defaults execute=false)
  for (const name of [
    "dictation_build",
    "dictation_sign",
    "dictation_deploy",
    "dictation_status",
  ]) {
    assert.deepEqual(byName.get(name).config.inputSchema.parse({}), {
      configuration: "debug",
      response_format: "markdown",
    });
  }
  for (const name of [
    "dictation_restart",
    "dictation_cert_status",
    "dictation_cert_ensure",
  ]) {
    assert.deepEqual(byName.get(name).config.inputSchema.parse({}), {
      response_format: "markdown",
    });
  }
  assert.deepEqual(byName.get("dictation_wipe").config.inputSchema.parse({}), {
    dry_run: true,
    response_format: "markdown",
  });
  assert.deepEqual(
    byName.get("dictation_cert_publish_github").config.inputSchema.parse({}),
    { execute: false, response_format: "markdown" },
  );

  // destructive vs read-only annotations
  assert.equal(byName.get("dictation_build").config.annotations.destructiveHint, false);
  assert.equal(byName.get("dictation_sign").config.annotations.destructiveHint, true);
  assert.equal(byName.get("dictation_deploy").config.annotations.destructiveHint, true);
  assert.equal(byName.get("dictation_restart").config.annotations.destructiveHint, true);
  assert.equal(byName.get("dictation_status").config.annotations.readOnlyHint, true);
  assert.equal(byName.get("dictation_status").config.annotations.destructiveHint, false);
  assert.equal(byName.get("dictation_wipe").config.annotations.destructiveHint, true);
  assert.equal(byName.get("dictation_wipe").config.annotations.idempotentHint, true);
  assert.equal(byName.get("dictation_cert_status").config.annotations.readOnlyHint, true);
  assert.equal(byName.get("dictation_cert_status").config.annotations.destructiveHint, false);
  assert.equal(byName.get("dictation_cert_ensure").config.annotations.destructiveHint, false);
  assert.equal(byName.get("dictation_cert_ensure").config.annotations.idempotentHint, true);
  assert.equal(byName.get("dictation_cert_publish_github").config.annotations.destructiveHint, true);
  assert.equal(byName.get("dictation_cert_publish_github").config.annotations.idempotentHint, true);
});

// ── Handlers (safe paths) ────────────────────────────────────────────────────

test("handleBuild fails fast without spawning when the toolchain is broken", async () => {
  const server = makeFakeServer();
  registerTools(server);
  const buildTool = server.registrations.find((r) => r.name === "dictation_build");

  const previous = process.env.SWIFT_TOOLCHAIN;
  process.env.SWIFT_TOOLCHAIN = "/nonexistent/dct-toolchain";
  try {
    const res = await buildTool.handler({
      configuration: "debug",
      response_format: "json",
    });
    assert.equal(res.structuredContent.success, false);
    assert.equal(res.structuredContent.exitCode, -1);
    assert.equal(res.structuredContent.configuration, "debug");
    assert.match(res.structuredContent.tail, /SWIFT_TOOLCHAIN/);
    // markdown requested → text is a string; here we requested JSON
    const parsed = JSON.parse(res.content[0].text);
    assert.equal(parsed.success, false);
    assert.deepEqual(res.structuredContent, parsed);
  } finally {
    if (previous === undefined) delete process.env.SWIFT_TOOLCHAIN;
    else process.env.SWIFT_TOOLCHAIN = previous;
  }
});

test("handleBuild renders markdown for a failing build", async () => {
  const server = makeFakeServer();
  registerTools(server);
  const buildTool = server.registrations.find((r) => r.name === "dictation_build");

  const previous = process.env.SWIFT_TOOLCHAIN;
  process.env.SWIFT_TOOLCHAIN = "/nonexistent/dct-toolchain";
  try {
    const res = await buildTool.handler({
      configuration: "release",
      response_format: "markdown",
    });
    assert.match(res.content[0].text, /# NanoDictate build/);
    assert.match(res.content[0].text, /configuration: `release`/);
    assert.match(res.content[0].text, /status: \*\*FAILED\*\* \(exit -1\)/);
  } finally {
    if (previous === undefined) delete process.env.SWIFT_TOOLCHAIN;
    else process.env.SWIFT_TOOLCHAIN = previous;
  }
});

test("handleDeploy gates on build failure (no sign/restart) when the toolchain is broken", async () => {
  const server = makeFakeServer();
  registerTools(server);
  const deployTool = server.registrations.find((r) => r.name === "dictation_deploy");

  const previous = process.env.SWIFT_TOOLCHAIN;
  process.env.SWIFT_TOOLCHAIN = "/nonexistent/dct-toolchain";
  try {
    const res = await deployTool.handler({
      configuration: "debug",
      response_format: "json",
    });
    assert.equal(res.structuredContent.success, false);
    assert.equal(res.structuredContent.build.success, false);
    assert.equal(res.structuredContent.sign, null);
    assert.equal(res.structuredContent.restart, null);
    assert.equal(res.structuredContent.detail, "build failed");
    const parsed = JSON.parse(res.content[0].text);
    assert.equal(parsed.detail, "build failed");
    assert.deepEqual(res.structuredContent, parsed);
  } finally {
    if (previous === undefined) delete process.env.SWIFT_TOOLCHAIN;
    else process.env.SWIFT_TOOLCHAIN = previous;
  }
});

test("handleStatus returns a shaped result from read-only probes", async () => {
  const server = makeFakeServer();
  registerTools(server);
  const statusTool = server.registrations.find((r) => r.name === "dictation_status");

  const res = await statusTool.handler({
    configuration: "debug",
    response_format: "markdown",
  });
  const sc = res.structuredContent;
  // Shape-only assertions — values depend on the machine, but never throw.
  assert.equal(typeof sc.agentRunning, "boolean");
  assert.ok(Array.isArray(sc.pids));
  assert.equal(typeof sc.launchAgentLoaded, "boolean");
  assert.equal(typeof sc.launchAgentDetail, "string");
  assert.equal(sc.binaryPath === null || typeof sc.binaryPath === "string", true);
  assert.ok(sc.codeSignature === null || typeof sc.codeSignature === "object");
  assert.equal(typeof sc.signatureStable, "boolean");
  assert.match(res.content[0].text, /# NanoDictate agent status/);

  // JSON format path on the same handler
  const jsonRes = await statusTool.handler({
    configuration: "debug",
    response_format: "json",
  });
  assert.deepEqual(JSON.parse(jsonRes.content[0].text), jsonRes.structuredContent);
});
// ── dictation_wipe / dictation_cert_* input schemas ─────────────────────────

test("new input schemas accept explicit values and reject unknown fields", () => {
  assert.deepEqual(
    WipeInputSchema.parse({ dry_run: false, response_format: "json" }),
    { dry_run: false, response_format: "json" },
  );
  assert.equal(WipeInputSchema.safeParse({ dry_run: "yes" }).success, false);
  assert.equal(WipeInputSchema.safeParse({ extra: true }).success, false);

  assert.deepEqual(CertStatusInputSchema.parse({}), {
    response_format: "markdown",
  });
  assert.equal(CertStatusInputSchema.safeParse({ extra: 1 }).success, false);
  assert.equal(CertEnsureInputSchema.safeParse({ extra: 1 }).success, false);

  assert.deepEqual(
    CertPublishInputSchema.parse({ execute: true, response_format: "json" }),
    { execute: true, response_format: "json" },
  );
  assert.equal(CertPublishInputSchema.safeParse({ execute: 1 }).success, false);
  assert.equal(CertPublishInputSchema.safeParse({ extra: true }).success, false);
});

test("new output schemas parse the wipe/cert contracts and reject bad enums", () => {
  const wipe = {
    success: false,
    dryRun: true,
    items: [
      {
        id: "brewFormula",
        label: "Homebrew formula nanodictate",
        status: "dryrun",
        detail: "present — would delete",
        command: null,
      },
    ],
    newcomerReady: false,
    manualCommands: ["sudo rm -f /Library/LaunchAgents/com.nanodictate.agent.plist"],
    leftover: ["rootPlist"],
    pidsAfter: [42],
    detail: "dry run",
  };
  assert.deepEqual(WipeOutputSchema.parse(wipe), wipe);
  assert.equal(
    WipeOutputSchema.safeParse({
      ...wipe,
      items: [{ ...wipe.items[0], status: "exploded" }],
    }).success,
    false,
  );
  assert.equal(WipeOutputSchema.safeParse({ ...wipe, success: "yes" }).success, false);

  const status = {
    success: true,
    identities: [{ sha1: "AB".repeat(20), name: CI_SIGNING_IDENTITY }],
    ciSigningPresent: true,
    devIdentityPresent: true,
    usableLocal: true,
    githubSecrets: { status: "unreachable", detail: "HTTP 403" },
    detail: "ok",
  };
  assert.deepEqual(CertStatusOutputSchema.parse(status), status);
  assert.equal(
    CertStatusOutputSchema.safeParse({
      ...status,
      githubSecrets: { status: "maybe", detail: "" },
    }).success,
    false,
  );
  assert.equal(
    CertStatusOutputSchema.safeParse({ ...status, identities: [{ sha1: 1, name: 2 }] })
      .success,
    false,
  );

  const ensure = {
    success: true,
    action: "created",
    ciSigningPresent: true,
    identities: [],
    warnings: [],
    detail: "created",
  };
  assert.deepEqual(CertEnsureOutputSchema.parse(ensure), ensure);
  assert.equal(
    CertEnsureOutputSchema.safeParse({ ...ensure, action: "recreated" }).success,
    false,
  );

  const publish = {
    success: true,
    executed: false,
    secretsState: "absent",
    localCertPresent: true,
    p12Base64: "ZmFrZS1wMTI=",
    password: "x",
    instructions: ["gh secret set ..."],
    detail: "prepared only",
  };
  assert.deepEqual(CertPublishOutputSchema.parse(publish), publish);
  const publishNull = CertPublishOutputSchema.parse({ ...publish, p12Base64: null, password: null });
  assert.equal(publishNull.p12Base64, null);
  assert.equal(
    CertPublishOutputSchema.safeParse({ ...publish, secretsState: "partial" }).success,
    false,
  );
});

// ── dictation_wipe / dictation_cert_* renderers ─────────────────────────────

test("wipeMarkdown renders dry-run, manual-sudo commands and leftovers", () => {
  const md = wipeMarkdown({
    success: false,
    dryRun: true,
    items: [
      { id: "brewFormula", label: "Homebrew formula nanodictate", status: "dryrun", detail: "present — would delete", command: null },
      { id: "userPlist", label: "User plist", status: "clean", detail: "not present", command: null },
      { id: "rootPlist", label: "Root plist", status: "manual-sudo", detail: "present — needs root", command: "sudo rm -f /Library/LaunchAgents/com.nanodictate.agent.plist" },
      { id: "agentProcesses", label: "Processes", status: "failed", detail: "still running", command: null },
    ],
    newcomerReady: false,
    manualCommands: ["sudo rm -f /Library/LaunchAgents/com.nanodictate.agent.plist"],
    leftover: ["rootPlist", "agentProcesses"],
    pidsAfter: [42],
    detail: "would remove 2 trace(s)",
  });
  assert.match(md, /# NanoDictate wipe/);
  assert.match(md, /mode: \*\*dry run\*\* \(nothing was deleted\)/);
  assert.match(md, /newcomer-ready: \*\*no\*\*/);
  assert.match(md, /НОВИЧОК НЕ ГОТОВ: ЕСТЬ ОСТАТКИ/);
  assert.match(md, /- `brewFormula` — would remove/);
  assert.match(md, /- `userPlist` — clean/);
  assert.match(md, /- `rootPlist` — MANUAL SUDO/);
  assert.match(md, /- `agentProcesses` — FAILED/);
  assert.match(md, /leftover: rootPlist, agentProcesses/);
  assert.match(md, /## Commands that need your sudo/);
  assert.match(md, /sudo rm -f \/Library\/LaunchAgents\/com\.nanodictate\.agent\.plist/);
});

test("certStatusMarkdown renders identities and GitHub secrets state", () => {
  const md = certStatusMarkdown({
    success: true,
    identities: [
      { sha1: "A".repeat(40), name: CI_SIGNING_IDENTITY },
      { sha1: "B".repeat(40), name: SIGNING_IDENTITY },
    ],
    ciSigningPresent: true,
    devIdentityPresent: true,
    usableLocal: true,
    githubSecrets: { status: "present", detail: "both secrets configured" },
    detail: `"${CI_SIGNING_IDENTITY}" is available locally`,
  });
  assert.match(md, /# NanoDictate CI certificate status/);
  assert.match(md, /usable locally \(`NanoDictate CI Signing`\): \*\*yes\*\*/);
  assert.match(md, /GitHub secrets: `present` — both secrets configured/);
  assert.match(md, new RegExp(`- \`${"A".repeat(40)}\` "${CI_SIGNING_IDENTITY}"`));
});

test("certEnsureMarkdown renders action, warnings and identity list", () => {
  const md = certEnsureMarkdown({
    success: true,
    action: "created",
    ciSigningPresent: true,
    identities: [{ sha1: "C".repeat(40), name: CI_SIGNING_IDENTITY }],
    warnings: ["set-key-partition-list did not complete non-interactively (exit 1)"],
    detail: "Created self-signed RSA-2048 codeSigning certificate",
  });
  assert.match(md, /# NanoDictate CI certificate ensure/);
  assert.match(md, /action: `created`/);
  assert.match(md, /status: \*\*OK\*\*/);
  assert.match(md, /identity present: \*\*yes\*\*/);
  assert.match(md, /## Warnings/);
  assert.match(md, /set-key-partition-list did not complete/);
});

test("certPublishMarkdown renders material and instructions", () => {
  const md = certPublishMarkdown({
    success: true,
    executed: false,
    secretsState: "absent",
    localCertPresent: true,
    p12Base64: "ZmFrZS1wMTI=",
    password: "pw",
    instructions: ["gh secret set NANODICTATE_SIGNING_P12 --body \"<p12Base64>\""],
    detail: "Prepared only",
  });
  assert.match(md, /# NanoDictate CI certificate → GitHub/);
  assert.match(md, /executed: no/);
  assert.match(md, /GitHub secrets state: `absent`/);
  assert.match(md, /## Material/);
  assert.match(md, /p12 password: `pw`/);
  assert.match(md, /ZmFrZS1wMTI=/);
  assert.match(md, /## Instructions/);
});

// ── dictation_wipe / dictation_cert_* handlers (injected fakes) ─────────────

/**
 * Unique temp home for the wipe/cert fakes. A shared hard-coded path would be
 * polluted by parallel runs and stale files could mask a "wrote no file"
 * regression; the cert export paths derive from this home (via the fake
 * spawns), so it must be unique per run. Removed after every test.
 */
const TOOLS_FAKE_HOME = mkdtempSync(join(tmpdir(), "nanodictate-tools-home-"));
afterEach(() => rmSync(TOOLS_FAKE_HOME, { recursive: true, force: true }));

function makeFakeDeps(opts = {}) {
  const calls = [];
  const state = opts.state ?? {};
  const runFn = async (cmd, args = []) => {
    calls.push({ cmd, args });
    if (cmd === "gh" && args[0] === "secret" && args[1] === "list") {
      return state.ghStatus === 0
        ? { status: 0, stdout: state.ghStdout ?? "", stderr: "" }
        : { status: 1, stdout: "", stderr: "HTTP 403" };
    }
    if (cmd === "gh" && args[0] === "secret" && args[1] === "set") {
      return { status: 0, stdout: "", stderr: "" };
    }
    if (cmd === "brew" && args[0] === "list") {
      return state.brewListed
        ? { status: 0, stdout: "nanodictate 0.0.12\n", stderr: "" }
        : { status: 1, stdout: "", stderr: "no" };
    }
    if (cmd === "brew" && args[0] === "--repository") {
      return state.brewRepository == null
        ? { status: 1, stdout: "", stderr: "brew: command not found" }
        : { status: 0, stdout: (state.brewRepository ?? "/opt/homebrew") + "\n", stderr: "" };
    }
    if (cmd === "security" && args[0] === "find-identity") {
      const lines = (state.identities ?? []).map((n, i) => `${i + 1}) ${"A".repeat(40)} "${n}"`).join("\n");
      return { status: 0, stdout: lines, stderr: "" };
    }
    if (cmd === "security" && args[0] === "export") {
      const idx = args.indexOf("-o");
      if (idx >= 0) writeFileSync(args[idx + 1], Buffer.from("fake-p12"));
      return { status: 0, stdout: "", stderr: "" };
    }
    if (cmd === "security" && args[0] === "import") {
      if (state.importFail) return { status: 1, stdout: "", stderr: "import failed" };
      state.identities = [...(state.identities ?? []), CI_SIGNING_IDENTITY];
      return { status: 0, stdout: "", stderr: "" };
    }
    if (cmd === "security" && args[0] === "set-key-partition-list") {
      return { status: 0, stdout: "", stderr: "" };
    }
    if (cmd === "/usr/bin/python3") {
      return { status: 0, stdout: "CN=" + (state.verifyCN ?? CI_SIGNING_IDENTITY), stderr: "" };
    }
    if (cmd === "defaults" && args[0] === "read") {
      return { status: 1, stdout: "", stderr: "does not exist" };
    }
    if (cmd === "/bin/launchctl" && args[0] === "print") {
      return { status: 1, stdout: "", stderr: "could not find service" };
    }
    if (cmd === "/usr/bin/pgrep") return { status: 1, stdout: "", stderr: "" };
    if (cmd === "/bin/ls") return { status: 1, stdout: "", stderr: "no such file" };
    throw new Error(`unhandled fake command: ${cmd} ${args.join(" ")}`);
  };
  return {
    calls,
    deps: { runFn, existsFn: () => false, home: TOOLS_FAKE_HOME, uid: "503" },
  };
}

test("handleWipe reports a clean machine as newcomer-ready", async () => {
  const fake = makeFakeDeps();
  const res = await handleWipe({}, fake.deps);
  const sc = res.structuredContent;
  assert.equal(WipeOutputSchema.safeParse(sc).success, true);
  assert.equal(sc.success, true);
  assert.equal(sc.newcomerReady, true);
  assert.equal(sc.dryRun, true);
  assert.ok(Array.isArray(sc.items) && sc.items.length === 15);
  const tcc = sc.items.find((i) => i.id === "tccRecords");
  assert.equal(tcc.status, "manual-sudo");
  assert.equal(sc.items.filter((i) => i.id !== "tccRecords").every((i) => i.status === "clean"), true);
  // the TCC manual block carries BOTH labels and BOTH commands — check (SELECT)
  // before erase (DELETE); the commands use the UDIR prefix, never $HOME
  assert.ok(sc.manualCommands.includes(TCC_GRANTS_CHECK_LABEL));
  assert.ok(sc.manualCommands.includes(TCC_GRANTS_LABEL));
  assert.ok(sc.manualCommands.includes(TCC_GRANTS_SELECT_CMD));
  assert.ok(sc.manualCommands.includes(TCC_GRANTS_DELETE_CMD));
  assert.ok(
    sc.manualCommands.indexOf(TCC_GRANTS_CHECK_LABEL) <
      sc.manualCommands.indexOf(TCC_GRANTS_LABEL),
  );
  assert.ok(sc.manualCommands.every((c) => !c.includes("$HOME/Library")));
  assert.ok(sc.manualCommands.some((c) => c.includes("SELECT service, client, auth_value")));
  assert.match(res.content[0].text, /# NanoDictate wipe/);
  assert.match(res.content[0].text, /НОВИЧОК ГОТОВ: ЧИСТО/);
  assert.match(res.content[0].text, /# TCC-grants\nUDIR=/);
  assert.match(res.content[0].text, /# TCC-grants-check/);
  assert.match(res.content[0].text, /erased manually/);
  // json format round-trips
  const jsonRes = await handleWipe({ response_format: "json" }, fake.deps);
  assert.deepEqual(JSON.parse(jsonRes.content[0].text), jsonRes.structuredContent);
});

test("handleWipe dry run on a dirty machine deletes nothing", async () => {
  const fake = makeFakeDeps({ state: { brewListed: true } });
  const res = await handleWipe({}, fake.deps);
  const sc = res.structuredContent;
  assert.equal(sc.success, false);
  assert.equal(sc.newcomerReady, false);
  assert.equal(sc.items.find((i) => i.id === "brewFormula").status, "dryrun");
  const runRealBrew = fake.calls.filter((c) => c.cmd === "brew");
  assert.equal(runRealBrew.some((c) => c.args[0] === "uninstall"), false);
});

test("handleCertStatus returns identities and secrets state without throwing", async () => {
  const fake = makeFakeDeps({
    state: { identities: [CI_SIGNING_IDENTITY, SIGNING_IDENTITY], ghStatus: 1 },
  });
  const res = await handleCertStatus({}, fake.deps);
  const sc = res.structuredContent;
  assert.equal(CertStatusOutputSchema.safeParse(sc).success, true);
  assert.equal(sc.ciSigningPresent, true);
  assert.equal(sc.devIdentityPresent, true);
  assert.equal(sc.githubSecrets.status, "unreachable");
  assert.match(res.content[0].text, /# NanoDictate CI certificate status/);
});

test("handleCertEnsure creates the identity on first run and is a no-op on the second", async () => {
  const fake = makeFakeDeps();
  const first = await handleCertEnsure({}, fake.deps);
  assert.equal(first.structuredContent.action, "created");
  assert.equal(first.structuredContent.ciSigningPresent, true);
  assert.equal(first.structuredContent.warnings.length, 0);
  const sc = first.structuredContent;
  assert.equal(CertEnsureOutputSchema.safeParse(sc).success, true);

  // same fake deps → identity already imported → no-op, nothing recreated
  const second = await handleCertEnsure({}, fake.deps);
  assert.equal(second.structuredContent.action, "exists");
  assert.match(second.content[0].text, /nothing was created or overwritten/);
  assert.match(second.content[0].text, /# NanoDictate CI certificate ensure/);
});

test("handleCertEnsure surfaces import failure as an error", async () => {
  const fake = makeFakeDeps({ state: { importFail: true } });
  const res = await handleCertEnsure({}, fake.deps);
  assert.equal(res.structuredContent.action, "error");
  assert.equal(res.structuredContent.success, false);
});

test("handleCertPublish with execute=true installs both secrets when absent is confirmed", async () => {
  const fake = makeFakeDeps({
    state: { identities: [CI_SIGNING_IDENTITY], ghStatus: 0, ghStdout: "" },
  });
  const res = await handleCertPublish({ execute: true }, fake.deps);
  const sc = res.structuredContent;
  assert.equal(CertPublishOutputSchema.safeParse(sc).success, true);
  assert.equal(sc.executed, true);
  assert.equal(sc.success, true);
  assert.equal(sc.secretsState, "absent");
  assert.ok(sc.p12Base64);
  const sets = fake.calls.filter((c) => c.cmd === "gh" && c.args[1] === "set");
  assert.equal(sets.length, 2);
  assert.equal(sets[0].args[2], "NANODICTATE_SIGNING_P12");
  assert.equal(sets[1].args[2], "NANODICTATE_SIGNING_PASSWORD");
  assert.match(res.content[0].text, /# NanoDictate CI certificate → GitHub/);
  assert.match(res.content[0].text, /executed: \*\*yes\*\*/);
});

test("handleCertPublish never overwrites existing secrets", async () => {
  const fake = makeFakeDeps({
    state: {
      identities: [CI_SIGNING_IDENTITY],
      ghStatus: 0,
      ghStdout: "NANODICTATE_SIGNING_P12\nNANODICTATE_SIGNING_PASSWORD\n",
    },
  });
  const res = await handleCertPublish({ execute: true }, fake.deps);
  assert.equal(res.structuredContent.executed, false);
  assert.equal(res.structuredContent.secretsState, "present");
  assert.match(res.structuredContent.detail, /refusing to overwrite/);
  const sets = fake.calls.filter((c) => c.cmd === "gh" && c.args[1] === "set");
  assert.equal(sets.length, 0);
  // json round-trip on the refuse path too
  const jsonRes = await handleCertPublish(
    { execute: true, response_format: "json" },
    fake.deps,
  );
  assert.deepEqual(JSON.parse(jsonRes.content[0].text), jsonRes.structuredContent);
});

test("handleCertPublish with execute=false prepares material but sends nothing", async () => {
  const fake = makeFakeDeps({
    state: { identities: [CI_SIGNING_IDENTITY], ghStatus: 0, ghStdout: "" },
  });
  const res = await handleCertPublish({ execute: false }, fake.deps);
  assert.equal(res.structuredContent.executed, false);
  assert.equal(res.structuredContent.success, true);
  assert.ok(res.structuredContent.p12Base64);
  assert.equal(fake.calls.some((c) => c.cmd === "gh" && c.args[1] === "set"), false);
});
