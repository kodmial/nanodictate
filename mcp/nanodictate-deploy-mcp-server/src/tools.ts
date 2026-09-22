/**
 * MCP tool definitions for the nanodictate-deploy-mcp-server.
 *
 * Five tools, all following the mcp-builder conventions:
 *   - names prefixed `dictation_`
 *   - strict Zod input schemas, tool annotations, output schemas
 *   - both markdown (human) and JSON (machine) response formats
 *
 * The tools operate on the MAIN checkout (the repo root — swift build +
 * codesign run there). See src/constants.ts for the layout.
 */

import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import {
  buildProject,
  getStatus,
  restartAgent,
  signProject,
  type BuildResult,
  type RestartResult,
  type SignResult,
  type StatusResult,
} from "./commands.js";
import { CONFIGURATIONS, SIGNING_IDENTITY } from "./constants.js";

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

// ── Response helpers ────────────────────────────────────────────────────────

type TextContent = { type: "text"; text: string };

export function respond<T>(text: string, structuredContent: T) {
  // The SDK types structuredContent as { [x: string]: unknown }; the cast at
  // this boundary is intentional — the data objects come from typed functions
  // in commands.ts.
  return {
    content: [{ type: "text" as const, text }] satisfies TextContent[],
    structuredContent: structuredContent as unknown as Record<string, unknown>,
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
      `- stable signature (identity = "${SIGNING_IDENTITY}"): ${r.signatureStable ? "**yes** — TCC grants preserved**" : "**NO** — re-grant Microphone/Accessibility after rebuild"}`,
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
        "\" --entitlements <file> --options runtime --identifier <bundle-id>` and verifies each with `codesign --verify --strict`. The fixed identity + fixed entitlements keep the cdhash stable so macOS keeps the Microphone/Accessibility TCC grants across rebuilds. Fails (does not create anything) if the identity is missing from the keychain." +
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
}