#!/usr/bin/env node
/**
 * nanodictate-deploy-mcp-server — MCP server entrypoint.
 *
 * stdio transport. Never write logs to stdout (that would corrupt the JSON-RPC
 * protocol); use stderr for diagnostics.
 */

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { registerTools } from "./tools.js";

const SERVER_NAME = "nanodictate-deploy";
const SERVER_VERSION = "1.0.0";

const server = new McpServer({
  name: SERVER_NAME,
  version: SERVER_VERSION,
});

registerTools(server);

async function main(): Promise<void> {
  const transport = new StdioServerTransport();
  // When the MCP client ends its stdin (quit / pipe close), exit instead of
  // idling forever.
  transport.onclose = () => {
    console.error(`${SERVER_NAME}: stdin closed, shutting down`);
    process.exit(0);
  };

  await server.connect(transport);
  console.error(`${SERVER_NAME} v${SERVER_VERSION} running via stdio`);
}

main().catch((err) => {
  console.error(`${SERVER_NAME}: fatal error:`, err);
  process.exit(1);
});