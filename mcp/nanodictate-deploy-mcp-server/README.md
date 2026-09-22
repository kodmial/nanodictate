# nanodictate-deploy-mcp-server

MCP (Model Context Protocol) server for building, signing and restarting the
macOS dictation agent — with a stable code signature so macOS keeps the
**Microphone / Accessibility TCC grants** across rebuilds.

| Property      | Value                     |
| ------------- | ------------------------- |
| Transport     | stdio                     |
| Protocol      | MCP over JSON-RPC (SDK)   |
| Runtime       | Node.js ≥ 22              |
| Language      | TypeScript (strict)       |

## Why a stable signature matters

macOS stores Accessibility / Microphone grants keyed to the binary's code
signature — its **designated requirement**, derived by `codesign` from the
signing identity, bundle identifier and entitlements. Two rebuilds signed
ad-hoc (or with a different identity) produce two different designated
requirements → the grants silently reset and the agent stops working until
the user re-grants permissions in System Settings.

The fix, applied by `dictation_sign` / `dictation_deploy`:

1. a **fixed signing identity** — the self-signed "NanoDictate Code Signing"
   certificate (create once via Keychain Access → Certificate Assistant);
2. **fixed entitlements plists** (`Resources/com.nanodictate.agent.entitlements`,
   `Resources/com.nanodictate.ctl.entitlements` in the repo root);
3. `codesign --force --sign "NanoDictate Code Signing" --entitlements <file>
   --options runtime --identifier <bundle-id> <binary>`.

The same identity + same entitlements + same identifier keep the designated
requirement stable, so the grants survive rebuilds. The cdhash (code
directory hash) itself **does change** across rebuilds — normal and expected,
not a sign of instability; the grants are preserved because the designated
requirement they are keyed to stays the same.

> Note: Accessibility is a TCC grant, not an entitlement — the stable
> designated requirement is what preserves it. The only capability entitlement
> the agent actually needs is
> `com.apple.security.device.audio-input` (microphone, used via
> `AVCaptureDevice`). `com.apple.security.automation.apple-events` is **not**
> included: no AppleScript/System Events usage was found in
> `Sources/NanoDictateAgent` or `Sources/NanoDictateCore`.

## Layout

```
repo root  $PROJECT_ROOT                              — swift build & codesign run HERE
             mcp/nanodictate-deploy-mcp-server/          — this server (same checkout)
             Resources/*.entitlements                  — signing entitlements
```

`swift build` and `codesign` target the **repo root** (the running agent is
launched from there). All source/entitlement files live in the same checkout:
the server's `SERVER_ROOT` (`src/constants.ts`) equals the project root, so
`resolveEntitlementsPath()` resolves from `<PROJECT_ROOT>/Resources/<name>`
directly and reports the source `"main-checkout"` | `"missing"` — the worktree
fallback probe (`"worktree"` source) no longer applies since the server merged
into the main checkout.

## Setup

```bash
cd mcp/nanodictate-deploy-mcp-server
npm install
npm run build          # tsc → dist/
node dist/index.js     # or configure as the MCP server command
```

On a fresh clone `dist/` and `node_modules/` are absent (both gitignored);
`start.sh` covers that: it installs dependencies (`npm ci`, falling back to
`npm install`) and runs the build when `dist/index.js` is missing, then
`exec`s the compiled server. Configure it as the MCP server in
`~/.claude/settings.json` / `.claude/settings.json`:

```json
{
  "mcpServers": {
    "nanodictate-deploy": {
      "command": "bash",
      "args": ["$PROJECT_ROOT/mcp/nanodictate-deploy-mcp-server/start.sh"]
    }
  }
}
```

($PROJECT_ROOT is the repo root; use the absolute path to your checkout — the
server resolves it from its own location, and `start.sh` needs no hardcoded paths.)

## Tools

All tools take `response_format` (`"markdown"` default | `"json"`) and return
both human-readable text and `structuredContent`.

| Tool                | Description                                                              |
| ------------------- | ------------------------------------------------------------------------ |
| `dictation_build`   | `swift build -c debug\|release` in the main checkout. Does not sign.      |
| `dictation_sign`    | Re-signs both binaries with "NanoDictate Code Signing" + entitlements + hardened runtime, then `codesign --verify --strict`. Fails cleanly if the identity is missing. |
| `dictation_deploy`  | One-call workflow: build → sign → restart (each step gated on the previous one). |
| `dictation_restart` | `launchctl kickstart -k gui/<uid>/com.nanodictate.agent` (fallback: `nanodictate start`). See note below. |
| `dictation_status`  | Process state, LaunchAgent state, code signature (identity, team id, entitlements), and `signatureStable` flag. |

### Examples (JSON-RPC)

```
dictation_status       → running, pids, launchd state, identity, entitlements
dictation_deploy       {"configuration": "debug"}   build+sign+restart
dictation_build        {"configuration": "release"}
dictation_sign         {"configuration": "debug"}
dictation_restart      {}
```

## Restart implementation note

The task assumed a `nanodictate restart` command — it does **not** exist in
`Sources/nanodictate/main.swift` (subcommands: start, stop, status, config,
provider, routing, transcribe, retry, last, logs, help). The restart tool
therefore calls the exact mechanism `nanodictate` itself uses internally
(`launchctl kickstart -k gui/$UID/com.nanodictate.agent`), falling back to
`nanodictate start` when kickstart fails. Inline-swapped plist is unchanged.

## Security considerations

- **No secrets** are read or written; the server only shells out to
  `swift`, `codesign`, `security`, `launchctl`, `pgrep`, `id`.
- Executes **mutating** commands (`codesign --force`, `launchctl kickstart -k`)
  — the tools are annotated `destructiveHint: true`, and clients should prompt
  before invoking `dictation_sign` / `dictation_deploy` / `dictation_restart`.
- `dictation_restart` cannot fail silently: a failed build never reaches sign,
  and a failed sign never reaches restart.
- `codesign --options runtime` enables the hardened runtime; the agent does not
  depend on disabled-by-default dyld environment variables.

## Troubleshooting

| Symptom | Fix |
| ------- | --- |
| `dictation_sign`: identity not found | Create "NanoDictate Code Signing" certificate in Keychain Access, then re-check with `security find-identity -p codesigning -v`. |
| `signatureStable: false` in status | Agent was signed ad-hoc/other identity — run `dictation_sign`, re-grant Microphone/Accessibility once. |
| `build.sh` used manually (removed 2026-09-16) | Historical comparison: the old build script signed with the *first* keychain identity (or fell back to ad-hoc), without entitlements. `dictation_sign` is now the only signer — it has no ad-hoc fallback and requires the "NanoDictate Code Signing" identity. |