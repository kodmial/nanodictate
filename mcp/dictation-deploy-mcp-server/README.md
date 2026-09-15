# dictation-deploy-mcp-server

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

macOS stores Accessibility / Microphone grants keyed to the code signature
(`cdhash`) of the binary. Two rebuilds signed ad-hoc are two different
signatures → the grants silently reset and the agent stops working until the
user re-grants permissions in System Settings.

The fix, applied by `dictation_sign` / `dictation_deploy`:

1. a **fixed signing identity** — the self-signed "Dictation Code Signing"
   certificate (create once via Keychain Access → Certificate Assistant →
   "Sign to Run Locally");
2. **fixed entitlements plists** (`Resources/com.dictation.agent.entitlements`,
   `Resources/com.dictation.dictatorctl.entitlements` in the worktree);
3. `codesign --force --sign "Dictation Code Signing" --entitlements <file>
   --options runtime --identifier <bundle-id> <binary>`.

Same identity + same entitlements + same code → same cdhash → grants survive.

> Note: Accessibility is a TCC grant, not an entitlement — the stable cdhash is
> what preserves it. The only capability entitlement the agent actually needs is
> `com.apple.security.device.audio-input` (microphone, used via
> `AVCaptureDevice`). `com.apple.security.automation.apple-events` is **not**
> included: no AppleScript/System Events usage was found in
> `Sources/DictatorAgent` or `Sources/DictationCore`.

## Layout

```
main checkout  /Users/dima/projects/dictation        — swift build & codesign run HERE
worktree       <repo>/.claude/worktrees/feat+long-file-gigaam
                 mcp/dictation-deploy-mcp-server/     — this server
                 Resources/*.entitlements             — signing entitlements
```

`swift build` and `codesign` target the **main checkout** (the running agent is
launched from there). All source/entitlement files live in the worktree; the
entitlement paths are resolved at runtime by `resolveEntitlementsPath()`
(`src/constants.ts`): first `<PROJECT_ROOT>/Resources/<name>`, then
`<SERVER_ROOT>/Resources/<name>`, returning the source
`"main-checkout"` | `"worktree"` | `"missing"`. Until the branch merges the
files only exist in the worktree; after the merge they land in the main
checkout (where `SERVER_ROOT` equals `PROJECT_ROOT`), so the lookup keeps
working without further edits.

## Setup

```bash
cd mcp/dictation-deploy-mcp-server
npm install
npm run build          # tsc → dist/
node dist/index.js     # or configure as the MCP server command
```

## Tools

All tools take `response_format` (`"markdown"` default | `"json"`) and return
both human-readable text and `structuredContent`.

| Tool                | Description                                                              |
| ------------------- | ------------------------------------------------------------------------ |
| `dictation_build`   | `swift build -c debug\|release` in the main checkout. Does not sign.      |
| `dictation_sign`    | Re-signs both binaries with "Dictation Code Signing" + entitlements + hardened runtime, then `codesign --verify --strict`. Fails cleanly if the identity is missing. |
| `dictation_deploy`  | One-call workflow: build → sign → restart (each step gated on the previous one). |
| `dictation_restart` | `launchctl kickstart -k gui/<uid>/com.dictation.agent` (fallback: `dictatorctl start`). See note below. |
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

The task assumed a `dictatorctl restart` command — it does **not** exist in
`Sources/dictatorctl/main.swift` (subcommands: start, stop, status, config,
provider, routing, transcribe, retry, last, logs, help). The restart tool
therefore calls the exact mechanism `dictatorctl` itself uses internally
(`launchctl kickstart -k gui/$UID/com.dictation.agent`), falling back to
`dictatorctl start` when kickstart fails. Inline-swapped plist is unchanged.

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
| `dictation_sign`: identity not found | Create "Sign to Run Locally" certificate in Keychain Access, then re-check with `security find-identity -p codesigning -v`. |
| `signatureStable: false` in status | Agent was signed ad-hoc/other identity — run `dictation_sign`, re-grant Microphone/Accessibility once. |
| `./build.sh` used manually | It signs with the *first* keychain identity (or ad-hoc). Prefer `dictation_deploy`; or run `SIGN_IDENTITY="Dictation Code Signing" ./build.sh` (still without entitlements). |