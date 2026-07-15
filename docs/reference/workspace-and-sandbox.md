# Workspace and sandbox

Sigil's file and shell tools operate inside a **sandboxed workspace** — the security
boundary for chat mode.

## The workspace jail

Every file tool (`ws_read` / `ws_write` / `ws_edit` / `ws_list`) is confined to one
directory: the `workspace` (default `~/.sigil/workspace`, set with
`configure workspace <path>`). A path that resolves outside the workspace is **refused**,
not clamped — there is no reading `/etc/passwd` or writing `../elsewhere`.

Check the current workspace with `/workspace` in chat or `sigil soul`.

## The exec gate

`ws_exec(command)` never runs a command unconditionally. It passes through two layers:

1. **Approval gate** (`approvals`) — the effective policy is the stricter of a security
   mode (`deny` / `allowlist` / `full`) and an ask mode (`off` / `on-miss` / `always`),
   plus a per-agent allowlist. A non-allowlisted command becomes *pending*; in the chat
   REPL you're prompted inline to approve it (once), otherwise it's blocked. Manage this
   with `sigil approvals …` (`get` / `set` / `allow` / `approve` / `elevate` / `audit`).
2. **Sandbox** — set by `sandbox_mode`:
   - `jail` (default) — a cwd-confined subprocess with the workspace as its working
     directory. Note: a shell command can still `cd` elsewhere, which is why exec is
     also approval-gated. Good for local, trusted use.
   - `docker` — runs the command in a locked-down container
     (`--network none --cap-drop ALL --security-opt no-new-privileges --pids-limit 256
     --memory 1g`) with only the workspace bind-mounted at `/work`. Requires Docker;
     set the image with `SIGIL_SANDBOX_IMAGE` (default `python:3.13-slim`).
   - `off` — `ws_exec` is disabled entirely.

## Web egress

`web_fetch` carries an **SSRF guard**: it refuses non-`http(s)` URLs and any loopback,
private (`10.`, `192.168.`, `172.16–31.`), or link-local (`169.254.`, cloud metadata)
host — so a tool can't be tricked into reaching internal services.

## Secrets

Secret values are never stored on the graph. A `SecretRef` maps a name to an environment
variable (`sigil secret add <name> <ENV_VAR>`); `secret:<name>` tokens resolve from the
environment only at run time, and any live secret value is redacted from tool output and
logs.
