/**
 * MCP tool definitions for the nanodictate-deploy-mcp-server.
 *
 * Nine tools, all following the mcp-builder conventions:
 *   - names prefixed `dictation_`
 *   - strict Zod input schemas, tool annotations, output schemas
 *   - both markdown (human) and JSON (machine) response formats
 *
 * The build/sign tools operate on the MAIN checkout (the repo root — swift
 * build + codesign run there). The wipe and certificate tools work on the
 * user's system state. See src/constants.ts for the layout.
 */

import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import {
  buildProject,
  ensureCiSigningIdentity,
  getCertStatus,
  getStatus,
  publishCiSigningToGithub,
  restartAgent,
  signProject,
  wipeProject,
  type BuildResult,
  type CertEnsureResult,
  type CertPublishResult,
  type CertStatusResult,
  type CommandDeps,
  type RestartResult,
  type SignResult,
  type StatusResult,
  type WipeResult,
} from "./commands.js";
import { CONFIGURATIONS, CI_SIGNING_IDENTITY, SIGNING_IDENTITY } from "./constants.js";

// ── Shared input pieces ─────────────────────────────────────────────────────

export enum ResponseFormat {
  MARKDOWN = "markdown",
  JSON = "json",
}

export const CONFIGURATION_SCHEMA = z.enum(CONFIGURATIONS);
export const RESPONSE_FORMAT_SCHEMA = z.nativeEnum(ResponseFormat);

export const CONFIG_PARAM = CONFIGURATION_SCHEMA.default("debug").describe(
  "Build configuration: 'debug' or 'release' (default 'debug')",
);
export const FORMAT_PARAM = RESPONSE_FORMAT_SCHEMA.default(ResponseFormat.MARKDOWN).describe(
  "Response format: 'markdown' for human-readable text, 'json' for machine-readable data",
);

// ── Output schemas (structuredContent contract) ────────────────────────────

export const SymlinkSchema = z.object({
  created: z.boolean(),
  target: z.string(),
  linkPath: z.string(),
  detail: z.string(),
});

export const BuildOutputSchema = z.object({
  success: z.boolean(),
  configuration: CONFIGURATION_SCHEMA,
  exitCode: z.number(),
  binaryPath: z.string(),
  symlink: SymlinkSchema,
  tail: z.string(),
});

export const SignBinarySchema = z.object({
  name: z.string(),
  path: z.string(),
  signed: z.boolean(),
  verified: z.boolean(),
  detail: z.string(),
});

export const SignOutputSchema = z.object({
  success: z.boolean(),
  configuration: CONFIGURATION_SCHEMA,
  identity: z.string(),
  binaries: z.array(SignBinarySchema),
  detail: z.string(),
});

export const RestartOutputSchema = z.object({
  success: z.boolean(),
  method: z.string(),
  detail: z.string(),
});

export const CodeSignatureSchema = z.object({
  signed: z.boolean(),
  identity: z.union([z.string(), z.null()]),
  teamId: z.union([z.string(), z.null()]),
  entitlements: z.union([z.record(z.string(), z.unknown()), z.null()]),
  entitlementsFile: z.union([z.string(), z.null()]),
});

export const StatusOutputSchema = z.object({
  agentRunning: z.boolean(),
  pids: z.array(z.number()),
  launchAgentLoaded: z.boolean(),
  launchAgentDetail: z.string(),
  binaryPath: z.union([z.string(), z.null()]),
  codeSignature: z.union([CodeSignatureSchema, z.null()]),
  signatureStable: z.boolean(),
});

export const DeployOutputSchema = z.object({
  success: z.boolean(),
  configuration: CONFIGURATION_SCHEMA,
  build: z.union([
    z.object({
      success: z.boolean(),
      exitCode: z.number(),
      binaryPath: z.string(),
      tail: z.string(),
    }),
    z.null(),
  ]),
  sign: z.union([
    z.object({
      success: z.boolean(),
      identity: z.string(),
      binaries: z.array(SignBinarySchema),
    }),
    z.null(),
  ]),
  restart: z.union([
    z.object({ success: z.boolean(), method: z.string() }),
    z.null(),
  ]),
  detail: z.string(),
});

export const WipeItemSchema = z.object({
  id: z.string(),
  label: z.string(),
  status: z.enum(["clean", "dryrun", "wiped", "failed", "manual-sudo"]),
  detail: z.string(),
  command: z.union([z.string(), z.null()]),
});

export const WipeOutputSchema = z.object({
  success: z.boolean(),
  dryRun: z.boolean(),
  items: z.array(WipeItemSchema),
  newcomerReady: z.boolean(),
  manualCommands: z.array(z.string()),
  leftover: z.array(z.string()),
  pidsAfter: z.array(z.number()),
  detail: z.string(),
});

export const IdentityEntrySchema = z.object({
  sha1: z.string(),
  name: z.string(),
});

export const GithubSecretsSchema = z.object({
  status: z.enum(["present", "absent", "unreachable"]),
  detail: z.string(),
});

export const CertStatusOutputSchema = z.object({
  success: z.boolean(),
  identities: z.array(IdentityEntrySchema),
  ciSigningPresent: z.boolean(),
  devIdentityPresent: z.boolean(),
  usableLocal: z.boolean(),
  githubSecrets: GithubSecretsSchema,
  detail: z.string(),
});

export const CertEnsureOutputSchema = z.object({
  success: z.boolean(),
  action: z.enum(["exists", "created", "error"]),
  ciSigningPresent: z.boolean(),
  identities: z.array(IdentityEntrySchema),
  warnings: z.array(z.string()),
  detail: z.string(),
});

export const CertPublishOutputSchema = z.object({
  success: z.boolean(),
  executed: z.boolean(),
  secretsState: z.enum(["present", "absent", "unreachable"]),
  localCertPresent: z.boolean(),
  // The p12 material and its password never travel through the tool result:
  // they live in 0600 files, and only the paths are returned. Every branch
  // (prepared-only, unreachable, failed publish) keeps the files so the
  // operator can run the `gh secret set ... < file` commands; a successful
  // publish removes them and returns null paths.
  materialPath: z.union([z.string(), z.null()]),
  passwordPath: z.union([z.string(), z.null()]),
  instructions: z.array(z.string()),
  detail: z.string(),
});

// ── Response helpers ────────────────────────────────────────────────────────

type TextContent = { type: "text"; text: string };

export function respond<T>(
  text: string,
  structuredContent: T,
  isErrorOverride?: boolean,
) {
  // The SDK types structuredContent as { [x: string]: unknown }; the cast at
  // this boundary is intentional — the data objects come from typed functions
  // in commands.ts.
  const data = structuredContent as Record<string, unknown>;
  // A result whose `success` flag is false must surface to the MCP client as an
  // error (isError), otherwise a failed build/sign/restart/deploy/wipe/cert
  // step is indistinguishable from a successful call. The deploy/status
  // handlers build their structured objects with a top-level `success` too.
  // `isErrorOverride` allows a handler to exempt a result whose `success:false`
  // is not a failure — e.g. a wipe dry run that probes and reports a plan.
  const isError = isErrorOverride ?? data.success === false;
  return {
    isError,
    content: [{ type: "text" as const, text }] satisfies TextContent[],
    structuredContent: data,
  };
}

/** Choose text representation per the requested response_format. */
export function render(
  format: ResponseFormat,
  markdown: string,
  data: unknown,
): string {
  return format === ResponseFormat.JSON
    ? JSON.stringify(data, null, 2)
    : markdown;
}

// ── Markdown renderers ──────────────────────────────────────────────────────

export function buildMarkdown(r: BuildResult): string {
  return [
    "# NanoDictate build",
    "",
    `- configuration: \`${r.configuration}\``,
    `- status: ${r.success ? "**OK**" : "**FAILED**"} (exit ${r.exitCode})`,
    `- binary: \`${r.binaryPath}\`${r.success ? "" : " (not created)"}`,
    `- symlink: ${r.symlink.created ? "**created**" : "NOT created"} — \`${r.symlink.detail}\``,
    "",
    "```",
    r.tail || "(no output)",
    "```",
  ].join("\n");
}

export function signMarkdown(r: SignResult): string {
  const lines: string[] = [
    "# NanoDictate sign",
    "",
    `- configuration: \`${r.configuration}\``,
    `- identity: \`${r.identity}\``,
    `- overall: ${r.success ? "**OK**" : "**FAILED**"}`,
    "",
  ];
  for (const b of r.binaries) {
    lines.push(
      `- ${b.name}: ` +
        (b.signed
          ? `**signed**${b.verified ? ", verified" : ", NOT verified"}`
          : `**NOT signed**`) +
        (b.detail !== "signed and verified" ? ` (${b.detail})` : ""),
    );
  }
  if (!r.success) lines.push("", r.detail);
  return lines.join("\n");
}

export function restartMarkdown(r: RestartResult): string {
  return [
    "# NanoDictate agent restart",
    "",
    `- status: ${r.success ? "**OK**" : "**FAILED**"}`,
    `- method: \`${r.method}\``,
    `- detail: ${r.detail}`,
    "",
  ].join("\n");
}

export function statusMarkdown(r: StatusResult): string {
  const lines: string[] = [
    "# NanoDictate agent status",
    "",
    "## Process",
    `- running: **${r.agentRunning ? "yes" : "no"}**`,
    `- pids: ${r.pids.length ? r.pids.join(", ") : "(none)"}`,
    "",
    "## LaunchAgent",
    `- loaded: ${r.launchAgentLoaded ? "**yes**" : "no"}`,
  ];
  if (r.launchAgentDetail) {
    lines.push("", "```", r.launchAgentDetail, "```");
  }
  lines.push("", "## Code signature");
  if (!r.binaryPath || !r.codeSignature) {
    lines.push(
      `- binary: ${r.binaryPath ?? "(not built)"} — run \`dictation_build\` first`,
    );
  } else {
    const sig = r.codeSignature;
    lines.push(
      `- signed: ${sig.signed ? "**yes**" : "no"}`,
      `- identity: \`${sig.identity ?? "(none)"}\``,
      sig.teamId ? `- team id: \`${sig.teamId}\`` : "- team id: (none)",
      `- entitlements file: ${sig.entitlementsFile ? `\`${sig.entitlementsFile}\`` : "(absent — dictation_sign will fail)"}`,
      `- stable signature (identity = "${SIGNING_IDENTITY}"): ${r.signatureStable ? "**yes** — TCC grants preserved" : "**NO** — re-grant Microphone/Accessibility after rebuild"}`,
    );
    if (sig.entitlements) {
      lines.push(
        "",
        "### Entitlements",
        ...Object.entries(sig.entitlements).map(
          ([k, v]) => `- ${k} = ${String(v)}`,
        ),
      );
    } else {
      lines.push("- entitlements: (none)");
    }
  }
  return lines.join("\n");
}

export function deployMarkdown(input: {
  configuration: "debug" | "release";
  success: boolean;
  build: BuildResult | null;
  sign: SignResult | null;
  restart: RestartResult | null;
  detail: string;
}): string {
  const lines: string[] = [
    "# NanoDictate deploy",
    "",
    `- configuration: \`${input.configuration}\``,
    `- overall: ${input.success ? "**OK**" : "**FAILED**"}`,
    "",
    "## Build",
    input.build
      ? `- ${input.build.success ? "**OK**" : "**FAILED**"} (exit ${input.build.exitCode}), binary \`${input.build.binaryPath}\`${input.build.success ? `, symlink ${input.build.symlink.created ? "created" : "NOT created"}` : ""}`
      : "- NOT RUN",
    "",
    "## Sign",
    input.sign
      ? `- ${input.sign.success ? "**OK**" : "**FAILED**"} — identity \`${input.sign.identity}\``
      : "- NOT RUN (build failed)",
    "",
    "## Restart",
    input.restart
      ? `- ${input.restart.success ? "**OK**" : "**FAILED**"} via \`${input.restart.method}\``
      : "- NOT RUN (previous step failed)",
  ];
  for (const b of input.sign?.binaries ?? []) {
    lines.push(`  - ${b.name}: ${b.signed ? "signed" : "NOT signed"}${b.verified ? ", verified" : ""}`);
  }
  if (input.sign && !input.sign.success) {
    lines.push("", input.sign.detail);
  }
  if (!input.success) lines.push("", `detail: ${input.detail}`);
  return lines.join("\n");
}

export function wipeMarkdown(r: WipeResult): string {
  const lines: string[] = [
    "# NanoDictate wipe",
    "",
    `- mode: ${r.dryRun ? "**dry run** (nothing was deleted)" : "**real wipe**"}`,
    `- newcomer-ready: **${r.newcomerReady ? "yes" : "no"}**`,
    // Canonical ТЗ verdict line, kept verbatim so the operator can grep for it.
    r.newcomerReady
      ? "- НОВИЧОК ГОТОВ: ЧИСТО"
      : "- НОВИЧОК НЕ ГОТОВ: ЕСТЬ ОСТАТКИ (leftover / manual sudo ниже)",
    `- overall: ${r.success ? "**OK**" : "**INCOMPLETE**"}`,
    r.detail,
    "",
    "## Items",
  ];
  for (const item of r.items) {
    const mark =
      item.status === "wiped"
        ? "wiped"
        : item.status === "clean"
          ? "clean"
          : item.status === "dryrun"
            ? "would remove"
            : item.status === "manual-sudo"
              ? "MANUAL SUDO"
              : "FAILED";
    lines.push(`- \`${item.id}\` — ${mark}: ${item.detail}`);
  }
  if (r.leftover.length > 0) {
    lines.push("", `leftover: ${r.leftover.join(", ")}`);
  }
  if (r.manualCommands.length > 0) {
    lines.push("", "## Commands that need your sudo (not executed here)", "", "```sh");
    lines.push(...r.manualCommands);
    lines.push("```");
  }
  return lines.join("\n");
}

export function certStatusMarkdown(r: CertStatusResult): string {
  const lines: string[] = [
    "# NanoDictate CI certificate status",
    "",
    `- usable locally (\`${CI_SIGNING_IDENTITY}\`): **${r.usableLocal ? "yes" : "no"}**`,
    `- dev identity \`${SIGNING_IDENTITY}\` present: ${r.devIdentityPresent ? "yes" : "no"}`,
    `- GitHub secrets: \`${r.githubSecrets.status}\` — ${r.githubSecrets.detail}`,
    "",
    "## Code-signing identities in the keychain",
  ];
  if (r.identities.length === 0) {
    lines.push("- (none found)");
  } else {
    for (const id of r.identities) {
      lines.push(`- \`${id.sha1}\` "${id.name}"`);
    }
  }
  lines.push("", r.detail);
  return lines.join("\n");
}

export function certEnsureMarkdown(r: CertEnsureResult): string {
  const lines: string[] = [
    "# NanoDictate CI certificate ensure",
    "",
    `- action: \`${r.action}\``,
    `- status: ${r.success ? "**OK**" : "**FAILED**"}`,
    `- identity present: **${r.ciSigningPresent ? "yes" : "no"}**`,
    "",
    r.detail,
  ];
  if (r.identities.length > 0) {
    lines.push("", "## Code-signing identities");
    for (const id of r.identities) {
      lines.push(`- \`${id.sha1}\` "${id.name}"`);
    }
  }
  if (r.warnings.length > 0) {
    lines.push("", "## Warnings");
    for (const w of r.warnings) lines.push(`- ${w}`);
  }
  return lines.join("\n");
}

export function certPublishMarkdown(r: CertPublishResult): string {
  const lines: string[] = [
    "# NanoDictate CI certificate → GitHub",
    "",
    `- executed: ${r.executed ? "**yes**" : "no"}`,
    `- GitHub secrets state: \`${r.secretsState}\``,
    `- local identity present: ${r.localCertPresent ? "yes" : "no"}`,
    "",
    r.detail,
  ];
  if (r.materialPath && r.passwordPath) {
    lines.push(
      "",
      "## Material (handle as a secret — these are the certificate private key files)",
      "",
      `- p12 material written to \`${r.materialPath}\` (mode 0600); not echoed here`,
      `- p12 password written to \`${r.passwordPath}\` (mode 0600); not echoed here`,
    );
  }
  if (r.instructions.length > 0) {
    lines.push("", "## Instructions", "");
    for (const line of r.instructions) lines.push(`- ${line}`);
  }
  return lines.join("\n");
}

// ── Tool handlers ───────────────────────────────────────────────────────────

export const BuildInputSchema = z
  .object({
    configuration: CONFIG_PARAM,
    response_format: FORMAT_PARAM,
  })
  .strict();
type BuildInput = z.infer<typeof BuildInputSchema>;

async function handleBuild(params: BuildInput) {
  const result = await buildProject(params.configuration);
  return respond(
    render(params.response_format, buildMarkdown(result), result),
    result,
  );
}

export const SignInputSchema = z
  .object({
    configuration: CONFIG_PARAM,
    response_format: FORMAT_PARAM,
  })
  .strict();
type SignInput = z.infer<typeof SignInputSchema>;

async function handleSign(params: SignInput) {
  const result = await signProject(params.configuration);
  return respond(
    render(params.response_format, signMarkdown(result), result),
    result,
  );
}

export const RestartInputSchema = z
  .object({
    response_format: FORMAT_PARAM,
  })
  .strict();
type RestartInput = z.infer<typeof RestartInputSchema>;

async function handleRestart(params: RestartInput) {
  const result = await restartAgent();
  return respond(
    render(params.response_format, restartMarkdown(result), result),
    result,
  );
}

export const StatusInputSchema = z
  .object({
    configuration: CONFIG_PARAM,
    response_format: FORMAT_PARAM,
  })
  .strict();
type StatusInput = z.infer<typeof StatusInputSchema>;

async function handleStatus(params: StatusInput) {
  const result = await getStatus(params.configuration);
  return respond(
    render(params.response_format, statusMarkdown(result), result),
    result,
  );
}

export const DeployInputSchema = z
  .object({
    configuration: CONFIG_PARAM,
    response_format: FORMAT_PARAM,
  })
  .strict();
type DeployInput = z.infer<typeof DeployInputSchema>;

async function handleDeploy(params: DeployInput) {
  const build = await buildProject(params.configuration);

  let sign: SignResult | null = null;
  let restart: RestartResult | null = null;

  if (build.success) {
    sign = await signProject(params.configuration);
  }
  if (build.success && sign?.success) {
    restart = await restartAgent();
  }

  const success =
    build.success && (sign?.success ?? false) && (restart?.success ?? false);

  const failureSteps: string[] = [];
  if (!build.success) failureSteps.push("build failed");
  if (sign && !sign.success) failureSteps.push("sign failed");
  if (restart && !restart.success) failureSteps.push("restart failed");

  const structured = {
    success,
    configuration: params.configuration,
    build: {
      success: build.success,
      exitCode: build.exitCode,
      binaryPath: build.binaryPath,
      tail: build.tail,
    },
    sign: sign
      ? {
          success: sign.success,
          identity: sign.identity,
          binaries: sign.binaries,
        }
      : null,
    restart: restart
      ? { success: restart.success, method: restart.method }
      : null,
    detail: failureSteps.length
      ? failureSteps.join("; ")
      : "build → sign → restart OK",
  };

  return respond(
    render(
      params.response_format,
      deployMarkdown({ ...structured, build, sign, restart }),
      structured,
    ),
    structured,
  );
}

export const WipeInputSchema = z
  .object({
    dry_run: z
      .boolean()
      .default(true)
      .describe(
        "true (default) probes the system and reports the wipe plan without deleting anything; false performs the cleanup, deleting only what the probe found, then verifies each item",
      ),
    response_format: FORMAT_PARAM,
  })
  .strict();
export type WipeInput = z.infer<typeof WipeInputSchema>;

export async function handleWipe(params: WipeInput, depsIn?: Partial<CommandDeps>) {
  const result = await wipeProject({ dryRun: params.dry_run, deps: depsIn });
  return respond(
    render(params.response_format, wipeMarkdown(result), result),
    result,
    // A dry run reports success:false when traces are found, but that is the
    // dry run doing its job (probe + plan) — never surface it as an MCP error,
    // or a client may retry or drop the plan.
    result.dryRun ? false : undefined,
  );
}

export const CertStatusInputSchema = z
  .object({
    response_format: FORMAT_PARAM,
  })
  .strict();
export type CertStatusInput = z.infer<typeof CertStatusInputSchema>;

export async function handleCertStatus(params: CertStatusInput, depsIn?: Partial<CommandDeps>) {
  const result = await getCertStatus(depsIn);
  return respond(
    render(params.response_format, certStatusMarkdown(result), result),
    result,
  );
}

export const CertEnsureInputSchema = z
  .object({
    response_format: FORMAT_PARAM,
  })
  .strict();
export type CertEnsureInput = z.infer<typeof CertEnsureInputSchema>;

export async function handleCertEnsure(params: CertEnsureInput, depsIn?: Partial<CommandDeps>) {
  const result = await ensureCiSigningIdentity(depsIn);
  return respond(
    render(params.response_format, certEnsureMarkdown(result), result),
    result,
  );
}

export const CertPublishInputSchema = z
  .object({
    execute: z
      .boolean()
      .default(false)
      .describe(
        "false (default) only prepares the p12 material and password in 0600 files plus the exact `gh secret set ... < file` commands and writes nothing; true runs those commands, but only when the secrets are confirmed absent",
      ),
    response_format: FORMAT_PARAM,
  })
  .strict();
export type CertPublishInput = z.infer<typeof CertPublishInputSchema>;

export async function handleCertPublish(params: CertPublishInput, depsIn?: Partial<CommandDeps>) {
  const result = await publishCiSigningToGithub({
    execute: params.execute,
    deps: depsIn,
  });
  return respond(
    render(params.response_format, certPublishMarkdown(result), result),
    result,
  );
}

// ── Registration ────────────────────────────────────────────────────────────

const SHARED_FOOTER =
  " The build/sign commands run from the repo root; if dist/ is missing, start.sh rebuilds automatically.";

export function registerTools(server: McpServer): void {
  server.registerTool(
    "dictation_build",
    {
      title: "Build dictation agent binaries",
      description:
        "Runs `swift build -c <configuration>` for the dictation macOS app and reports the resulting binary path. Does not sign or restart the agent — combine with dictation_sign / dictation_deploy." +
        SHARED_FOOTER,
      inputSchema: BuildInputSchema,
      outputSchema: BuildOutputSchema,
      annotations: {
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false,
      },
    },
    handleBuild,
  );

  server.registerTool(
    "dictation_sign",
    {
      title: "Sign dictation binaries with the stable identity",
      description:
        "Signs .build/<configuration>/{NanoDictateAgent,nanodictate} with `codesign --force --sign \"" +
        SIGNING_IDENTITY +
        "\" --entitlements <file> --options runtime --identifier <bundle-id>` and verifies each with `codesign --verify --strict`. macOS keys the Microphone/Accessibility TCC grants to the signature's designated requirement — identity + bundle id + entitlements — which the fixed identity keeps stable across rebuilds; the cdhash itself changes between rebuilds, which is normal and not a sign of instability. Fails (does not create anything) if the identity is missing from the keychain." +
        SHARED_FOOTER,
      inputSchema: SignInputSchema,
      outputSchema: SignOutputSchema,
      annotations: {
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: true,
        openWorldHint: false,
      },
    },
    handleSign,
  );

  server.registerTool(
    "dictation_deploy",
    {
      title: "Build, sign and restart the dictation agent",
      description:
        "Full workflow in one call: swift build → codesign both binaries with the stable identity → restart the LaunchAgent (launchctl kickstart -k gui/<uid>/com.nanodictate.agent). Each step runs only if the previous one succeeded, so a failed build never restarts the running agent with a broken binary." +
        SHARED_FOOTER,
      inputSchema: DeployInputSchema,
      outputSchema: DeployOutputSchema,
      annotations: {
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: true,
        openWorldHint: false,
      },
    },
    handleDeploy,
  );

  server.registerTool(
    "dictation_restart",
    {
      title: "Restart the dictation LaunchAgent",
      description:
        "Restarts the com.nanodictate.agent LaunchAgent via `launchctl kickstart -k gui/<uid>/com.nanodictate.agent` (the same mechanism `nanodictate`'s internal restart uses; there is no `nanodictate restart` command). Falls back to `nanodictate start` if kickstart fails (e.g. the agent was never loaded). Note: macOS does not reload the code signature from disk on kickstart — run dictation_sign before restarting for TCC-preserving rebuilds.",
      inputSchema: RestartInputSchema,
      outputSchema: RestartOutputSchema,
      annotations: {
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: true,
        openWorldHint: false,
      },
    },
    handleRestart,
  );

  server.registerTool(
    "dictation_status",
    {
      title: "Show dictation agent status and code signature",
      description:
        "Reports: process state (pgrep -f NanoDictateAgent), LaunchAgent load state (launchctl print gui/<uid>/com.nanodictate.agent), and the code signature of .build/<configuration>/NanoDictateAgent (codesign -dv: signing identity, team id, entitlements). signatureStable = true means the identity matches \"" +
        SIGNING_IDENTITY +
        "\" and TCC grants are preserved.",
      inputSchema: StatusInputSchema,
      outputSchema: StatusOutputSchema,
      annotations: {
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false,
      },
    },
    handleStatus,
  );

  server.registerTool(
    "dictation_wipe",
    {
      title: "Wipe every nanodictate trace from this machine",
      description:
        "Idempotent, probe-first cleanup: each candidate (Homebrew formula, local tap clone, Homebrew caches, MacPorts port, launchd service, user/root LaunchAgent plists, config, logs, ~/.nanodictate*, /usr/local/bin/nanodictate symlink, Accessibility cooldown stamp, running processes) is checked first and only deleted when it actually exists — a second run on a clean machine deletes nothing and still reports success. Root-owned files are reported with the exact sudo command instead of being attempted. The agent itself never executes commands against the TCC databases (system + per-user) non-interactively; nanodictate's own Accessibility/Microphone grants are erased by the exact \"TCC-grants\" sudo command included in the output. The GitHub repo/tap/manifests and unrelated applications are never touched. dry_run defaults to true.",
      inputSchema: WipeInputSchema,
      outputSchema: WipeOutputSchema,
      annotations: {
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: true,
        openWorldHint: false,
      },
    },
    // Registered without the second (deps) argument: the SDK passes
    // RequestHandlerExtra there. Tests call handleWipe directly with fakes.
    (params) => handleWipe(params),
  );

  server.registerTool(
    "dictation_cert_status",
    {
      title: "Show the CI signing certificate status",
      description:
        "Reports the code-signing identities in the local keychain (`security find-identity -p codesigning -v`), whether \"" +
        CI_SIGNING_IDENTITY +
        "\" is available locally for codesign, whether the dev identity \"" +
        SIGNING_IDENTITY +
        "\" is present, and a best-effort probe of the GitHub secrets " +
        "NANODICTATE_SIGNING_P12 / NANODICTATE_SIGNING_PASSWORD (reported as unreachable, never an error, when gh cannot read them). Read-only.",
      inputSchema: CertStatusInputSchema,
      outputSchema: CertStatusOutputSchema,
      annotations: {
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: true,
      },
    },
    // Tests call handleCertStatus directly with fakes.
    (params) => handleCertStatus(params),
  );

  server.registerTool(
    "dictation_cert_ensure",
    {
      title: "Create the local CI signing identity",
      description:
        "Mirrors the certificate recipe of .github/workflows/release.yml locally: a self-signed RSA-2048 X.509 certificate with the codeSigning extended key usage, named \"" +
        CI_SIGNING_IDENTITY +
        "\", generated with python3 + cryptography (certtool cannot express the EKU; the system openssl is LibreSSL without -addext), then imported with `security import -T /usr/bin/codesign` and given a key partition list so codesign can use it. Never overwrites: if an identity with that name already exists the tool is a no-op. The dev identity \"" +
        SIGNING_IDENTITY +
        "\" is never touched.",
      inputSchema: CertEnsureInputSchema,
      outputSchema: CertEnsureOutputSchema,
      annotations: {
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false,
      },
    },
    // Tests call handleCertEnsure directly with fakes.
    (params) => handleCertEnsure(params),
  );

  server.registerTool(
    "dictation_cert_publish_github",
    {
      title: "Install the CI certificate into GitHub secrets",
      description:
        "Exports the local \"" +
        CI_SIGNING_IDENTITY +
        "\" identity as a password-protected p12 and installs it as the GitHub secrets " +
        "NANODICTATE_SIGNING_P12 (base64 p12) and NANODICTATE_SIGNING_PASSWORD that the release workflow reads. Never overwrites: if those secrets already exist, or gh cannot be reached to confirm they are absent, nothing is written. With execute=false (default) it only prepares the material and the exact `gh secret set` commands.",
      inputSchema: CertPublishInputSchema,
      outputSchema: CertPublishOutputSchema,
      annotations: {
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: true,
        openWorldHint: true,
      },
    },
    // Tests call handleCertPublish directly with fakes.
    (params) => handleCertPublish(params),
  );
}