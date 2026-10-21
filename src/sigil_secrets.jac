"""SecretRef indirection — OpenClaw parity for secrets.

A `SecretRef` node maps a friendly name to an environment variable; the secret
VALUE is never stored on the graph (jac.toml / the session DB are tracked/observable).
References of the form `secret:<name>` resolve from the environment at run-time only,
and `redact_secrets` masks any live secret value anywhere config/tools/results print —
so a token never lands in `soul`, logs, or the Observatory.
"""

import os;
import from .sigil_core { awaken, Soul }

edge Holds: any --> any {}   # Soul -> SecretRef

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

def secret_list() -> list[any] {
    # names + their env var + whether the env is currently set — never the value
    soul = awaken();
    out: list[any] = [];
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

def secret_test(name: str) -> dict[str, any] {
    # prove resolution + redaction WITHOUT ever printing the value
    val = resolve_secret(name);
    demo = resolve_refs("token=secret:" + name);
    return {"name": name, "resolvable": bool(val), "length": len(val), "redacted": redact_secrets(demo)};
}

# ---------------------------------------------------------------------------
# Values typed into the console.
#
# A SecretRef names an environment variable, and until now the only way to give
# that variable a value was to export it in the shell that started Sigil. The
# console's Keys & secrets page needs somewhere to put a key a person pastes in,
# and it is not the graph (observable, synced) or jac.toml (git-tracked). It is
# one file under $SIGIL_HOME, created 0600, read into the environment when a
# process starts. A variable the shell already exported always wins: the file
# fills gaps, it never overrides what the user set by hand.
# ---------------------------------------------------------------------------
glob SECRETS_ENV_NAME: str = "secrets.env";

def secrets_env_path() -> str {
    # Lazy: sigil_runtime is imported by half the tree, and this module is too.
    import from .sigil_runtime { sigil_home }
    return os.path.join(sigil_home(), SECRETS_ENV_NAME);
}

def env_name_ok(name: str) -> bool {
    # A shell variable name: letters, digits, underscore, not starting with a digit.
    n = str(name or "");
    if (not n) or (len(n) > 128) { return False; }
    if n[0].isdigit() { return False; }
    for ch in n {
        if not (ch.isalnum() or (ch == "_")) { return False; }
        if ord(ch) > 127 { return False; }
    }
    return True;
}

def read_secret_env() -> dict[str, str] {
    # name -> value from the console's file. Never raises; a missing or unreadable
    # file is simply no values.
    out: dict[str, str] = {};
    path = secrets_env_path();
    if not os.path.exists(path) { return out; }
    try {
        with open(path) as f { text = f.read(); }
    } except Exception as e { return out; }
    for line in text.splitlines() {
        s = line.strip();
        if (not s) or s.startswith("#") or ("=" not in s) { continue; }
        parts = s.split("=", 1);
        k = parts[0].strip();
        if env_name_ok(k) and parts[1] { out[k] = parts[1]; }
    }
    return out;
}

def load_secret_env() -> int {
    # Called once at process start. The shell wins: a variable already set is
    # never replaced by the file's copy.
    n = 0;
    for (k, v) in read_secret_env().items() {
        if not os.environ.get(k) { os.environ[k] = v; n += 1; }
    }
    return n;
}

def _write_secret_env(vals: dict[str, str]) {
    path = secrets_env_path();
    lines: list[str] = [
        "# Keys saved from Sigil's console. A variable exported in your shell takes precedence.",
        "# NAME=value, one per line. Sigil creates this file readable by you alone (0600)."
    ];
    for k in sorted(vals.keys()) { lines.append(k + "=" + vals[k]); }
    tmp = path + ".tmp";
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600);
    with os.fdopen(fd, "w") as f { f.write("\n".join(lines) + "\n"); }
    os.chmod(tmp, 0o600);
    os.replace(tmp, path);
}

def secret_value_set(env: str, value: str) -> dict[str, any] {
    # Store one value in the console's file and in this process's environment, so
    # every child started from now on inherits it.
    if not env_name_ok(env) { return {"ok": False, "error": "'" + str(env) + "' is not a valid variable name"}; }
    v = str(value or "");
    if ("\n" in v) or ("\r" in v) { return {"ok": False, "error": "a key cannot contain a line break"}; }
    v = v.strip();
    if not v { return {"ok": False, "error": "the value is empty"}; }
    vals = read_secret_env();
    vals[env] = v;
    _write_secret_env(vals);
    os.environ[env] = v;
    return {"ok": True, "env": env, "file": secrets_env_path()};
}

def secret_value_clear(env: str) -> dict[str, any] {
    # Drop a value the console stored. A value that came from the shell is not the
    # console's to remove, so it stays.
    vals = read_secret_env();
    if env not in vals { return {"ok": True, "env": env, "removed": False}; }
    stored = vals[env];
    del vals[env];
    _write_secret_env(vals);
    if os.environ.get(env) == stored { del os.environ[env]; }
    return {"ok": True, "env": env, "removed": True};
}

def secret_source(env: str) -> str {
    # Where a variable's live value came from: "console", "shell", or "" (unset).
    val = str(os.environ.get(env) or "");
    if not val { return ""; }
    return "console" if read_secret_env().get(env) == val else "shell";
}

def secret_tail(env: str) -> str {
    # The last four characters, for telling two keys apart. Only for values long
    # enough that four characters reveal nothing useful.
    val = str(os.environ.get(env) or "");
    return val[-4:] if len(val) >= 16 else "";
}
