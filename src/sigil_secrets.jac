"""SecretRef indirection — OpenClaw parity for secrets.

A `SecretRef` node maps a friendly name to an environment variable; the secret
VALUE is never stored on the graph (jac.toml / the session DB are tracked/observable).
References of the form `secret:<name>` resolve from the environment at run-time only,
and `redact_secrets` masks any live secret value anywhere config/tools/results print —
so a token never lands in `soul`, logs, or the Observatory.
"""

import os;
import from .sigil_core { awaken, Soul }

edge Holds {}   # Soul -> SecretRef

node SecretRef {
    has name: str;
    has env: str;   # the env var that holds the value; the value itself is NEVER stored
}

def _refs(soul: Soul) -> list[SecretRef] { return [soul -->[?:SecretRef]]; }

def secret_add(name: str, env: str) -> str {
    soul = awaken();
    for r in _refs(soul) { if r.name == name { r.env = env; return "secret '" + name + "' -> $" + env + " (updated)"; } }
    soul +>:Holds:+> SecretRef(name=name, env=env);
    return "secret '" + name + "' -> $" + env;
}

def secret_remove(name: str) -> str {
    soul = awaken();
    for r in _refs(soul) { if r.name == name { del r; return "removed secret '" + name + "'"; } }
    return "no such secret: " + name;
}

def secret_list() -> list {
    # names + their env var + whether the env is currently set — never the value
    soul = awaken();
    out: list = [];
    for r in _refs(soul) { out.append({"name": r.name, "env": r.env, "set": bool(os.getenv(r.env))}); }
    return out;
}

def resolve_secret(name: str) -> str {
    soul = awaken();
    for r in _refs(soul) { if r.name == name { return str(os.getenv(r.env, "")); } }
    return "";
}

def resolve_refs(text: str) -> str {
    # replace every 'secret:<name>' token with its resolved value (run-time only)
    soul = awaken();
    out = text;
    for r in _refs(soul) {
        val = str(os.getenv(r.env, ""));
        if val { out = out.replace("secret:" + r.name, val); }
    }
    return out;
}

def has_unresolved(text: str) -> bool {
    # A `secret:` reference whose env var is unset survives resolve_refs verbatim,
    # and the literal string "secret:tg_token" is perfectly truthy. A caller that
    # only checked for emptiness would hand that to a provider as a credential —
    # a bridge long-polling Telegram forever with a token that is the word
    # "secret". Callers that need a real value ask this first.
    return "secret:" in str(text or "");
}

def resolve_credential(text: str) -> str {
    # The resolved value, or "" when anything in it is still a dangling reference.
    raw = str(text or "");
    if not raw { return ""; }
    out = str(resolve_refs(raw));
    return "" if has_unresolved(out) else out;
}

def redact_secrets(text: str) -> str {
    # mask any live secret value appearing in text so it never prints / logs
    soul = awaken();
    out = text;
    for r in _refs(soul) {
        val = str(os.getenv(r.env, ""));
        if val and (val in out) { out = out.replace(val, "***" + r.name + "***"); }
    }
    return out;
}

def secret_test(name: str) -> dict {
    # prove resolution + redaction WITHOUT ever printing the value
    val = resolve_secret(name);
    demo = resolve_refs("token=secret:" + name);
    return {"name": name, "resolvable": bool(val), "length": len(val), "redacted": redact_secrets(demo)};
}
