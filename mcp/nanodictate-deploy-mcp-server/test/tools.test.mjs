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

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  BuildOutputSchema,
  BuildInputSchema,
  CONFIGURATION_SCHEMA,
  CONFIG_PARAM,
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
  buildMarkdown,
  deployMarkdown,
  registerTools,
  render,
  restartMarkdown,
  respond,
  signMarkdown,
  statusMarkdown,
} from "../dist/tools.js";

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
  assert.match(running, /stable signature \(identity = "NanoDictate Code Signing"\): \*\*yes\*\* — TCC grants preserved\*\*/);
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

test("registerTools registers all five tools with schemas and annotations", () => {
  const server = makeFakeServer();
  registerTools(server);
  const byName = new Map(server.registrations.map((r) => [r.name, r]));

  assert.deepEqual(
    [...byName.keys()].sort(),
    [
      "dictation_build",
      "dictation_deploy",
      "dictation_restart",
      "dictation_sign",
      "dictation_status",
    ].sort(),
  );

  for (const [, r] of byName) {
    assert.equal(typeof r.config.inputSchema.safeParse, "function");
    assert.equal(typeof r.config.outputSchema.safeParse, "function");
    assert.equal(typeof r.handler, "function");
    assert.equal(typeof r.config.title, "string");
    assert.match(r.config.description, /./);
  }

  // input-schema defaults per tool (restart has no configuration param)
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
  assert.deepEqual(byName.get("dictation_restart").config.inputSchema.parse({}), {
    response_format: "markdown",
  });

  // destructive vs read-only annotations
  assert.equal(byName.get("dictation_build").config.annotations.destructiveHint, false);
  assert.equal(byName.get("dictation_sign").config.annotations.destructiveHint, true);
  assert.equal(byName.get("dictation_deploy").config.annotations.destructiveHint, true);
  assert.equal(byName.get("dictation_restart").config.annotations.destructiveHint, true);
  assert.equal(byName.get("dictation_status").config.annotations.readOnlyHint, true);
  assert.equal(byName.get("dictation_status").config.annotations.destructiveHint, false);
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