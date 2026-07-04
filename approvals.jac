"""Exec-approvals — OpenClaw parity: the security gate around risky (exec) tools.

OpenClaw's model: effective policy is the STRICTER of `tools.exec.security`
(deny | allowlist | full) and `tools.exec.ask` (off | on-miss | always), plus a
per-agent allowlist and a pending-approval flow (allow-once/allow-always/deny).
Prometheus models the policy + allowlist + pending approvals on the graph; any
exec-capable tool consults `check_exec(cmd)` before running.
"""

import from prometheus { awaken, Soul }

edge Governs {}    # Soul -> ExecPolicy
edge Allows {}     # ExecPolicy -> AllowRule
edge Pending {}    # ExecPolicy -> Approval

node ExecPolicy {
    has security: str = "allowlist";   # deny | allowlist | full
    has ask: str = "on-miss";          # off | on-miss | always
}

node AllowRule { has pattern: str; }

node Approval {
    has cmd: str;
    has status: str = "pending";       # pending | allow-once | allow-always | deny
    has ts: float = 0.0;
}

def _ts() -> float { import time; return time.time(); }

def _policy() -> ExecPolicy {
    soul = awaken();
    found = [soul -->[?:ExecPolicy]];
    if found { return found[0]; }
    p = ExecPolicy();
    soul +>:Governs:+> p;
    return p;
}

def approvals_get() -> dict {
    p = _policy();
    rules = [r.pattern for r in [p -->[?:AllowRule]]];
    pend = [{"cmd": a.cmd, "status": a.status} for a in [p -->[?:Approval]] if a.status == "pending"];
    return {"security": p.security, "ask": p.ask, "allowlist": rules, "pending": pend};
}

def approvals_set(security: str, ask: str) -> str {
    p = _policy();
    if security { p.security = security; }
    if ask { p.ask = ask; }
    return "exec policy: security=" + p.security + " ask=" + p.ask;
}

def allowlist_add(pattern: str) -> str {
    p = _policy();
    for r in [p -->[?:AllowRule]] { if r.pattern == pattern { return "already allowed: " + pattern; } }
    p +>:Allows:+> AllowRule(pattern=pattern);
    return "allowlisted: " + pattern;
}

def allowlist_remove(pattern: str) -> str {
    p = _policy();
    for r in [p -->[?:AllowRule]] { if r.pattern == pattern { del r; return "removed: " + pattern; } }
    return "not in allowlist: " + pattern;
}

def _matches(cmd: str, patterns: list) -> bool {
    # bare-name match (first token) or prefix/glob-prefix
    import fnmatch;
    tok = cmd.strip().split(" ")[0] if cmd.strip() else "";
    for pat in patterns {
        p2 = str(pat);
        if fnmatch.fnmatch(cmd, p2) or fnmatch.fnmatch(tok, p2) or cmd.startswith(p2) { return True; }
    }
    return False;
}

def _pend(p: ExecPolicy, cmd: str) -> dict {
    a = Approval(cmd=cmd, status="pending", ts=_ts());
    p +>:Pending:+> a;
    return {"decision": "approval-pending", "cmd": cmd, "reason": "awaiting operator approval"};
}

def check_exec(cmd: str) -> dict {
    # The gate an exec tool consults. Returns decision: allow | deny | approval-pending.
    p = _policy();
    if p.security == "deny" {
        return {"decision": "deny", "reason": "exec.security=deny"};
    }
    rules = [r.pattern for r in [p -->[?:AllowRule]]];
    if p.security == "full" {
        if p.ask == "always" { return _pend(p, cmd); }
        return {"decision": "allow", "reason": "exec.security=full"};
    }
    # allowlist mode
    if _matches(cmd, rules) {
        if p.ask == "always" { return _pend(p, cmd); }
        return {"decision": "allow", "reason": "allowlisted"};
    }
    if (p.ask == "on-miss") or (p.ask == "always") { return _pend(p, cmd); }
    return {"decision": "deny", "reason": "not allowlisted, ask=off"};
}

def approve(cmd_prefix: str, decision: str) -> str {
    p = _policy();
    for a in [p -->[?:Approval]] {
        if (a.status == "pending") and a.cmd.startswith(cmd_prefix) {
            a.status = decision;
            if decision == "allow-always" { p +>:Allows:+> AllowRule(pattern=a.cmd.split(" ")[0]); }
            return "resolved '" + a.cmd[:40] + "' -> " + decision;
        }
    }
    return "no pending approval matching: " + cmd_prefix;
}
