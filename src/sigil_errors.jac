"""Graceful model-failure handling — one sentence to the human, the story to a log.

A model call fails in mundane ways: a model name that doesn't exist, an expired
key, a rate limit, no network. byLLM answers each one by logging the full
traceback to stderr (once per retry) and litellm adds a three-line "Give
Feedback / Provider List" banner — all of it printed straight over the live
TUI. None of that helps the person in the chat, and none of it says what to DO.

The contract here:

  * the TERMINAL gets one short sentence naming the problem and the fix,
  * the ERROR LOG (`$SIGIL_HOME/log/error.log`, next to the daemon's log) gets
    everything — timestamps, context, tracebacks — for actual debugging.

`install_error_log()` runs once per process (src/main.jac's entry): it re-points
loguru (byLLM's logger) and litellm's stdlib loggers at the file and switches
litellm's banner off. `friendly_llm_error()` maps a caught exception to the
sentence; `log_error()` appends the full story to the file.
"""

import os;
import re;
import from pathlib { Path }
import from .sigil_runtime { sigil_home }

glob _INSTALLED: dict[str, bool] = {"done": False};

def error_log_path() -> str {
    # Same directory as the daemon's log ($SIGIL_HOME/log), so there is one
    # place to look when something went wrong.
    d = os.path.join(sigil_home(), "log");
    try { Path(d).mkdir(parents=True, exist_ok=True); } except Exception {}
    return os.path.join(d, "error.log");
}

def install_error_log() -> str {
    # Idempotent — the CLI installs at entry; a second call is a no-op.
    # Every hook is best-effort: a missing library must never break startup.
    if _INSTALLED["done"] { return error_log_path(); }
    _INSTALLED["done"] = True;
    path = error_log_path();
    # byLLM logs every failed provider call — once per retry — as a full
    # traceback on loguru's default stderr sink, on top of the live TUI.
    # Re-point loguru at the file. WARNING+: failures land, chatter doesn't.
    try {
        import from loguru { logger }
        logger.remove();
        logger.add(path, level="WARNING", rotation="1 MB", retention=2);
    } except Exception {}
    # litellm prints a three-line "Give Feedback / Provider List" banner to
    # stdout on every mapped exception. It ships an off switch — use it.
    try {
        import litellm;
        litellm.suppress_debug_info = True;
    } except Exception {}
    # ...and litellm's stdlib loggers (retry notices, cost-map grumbles)
    # follow the same rule: the file, never the terminal.
    try {
        import logging;
        fh = logging.FileHandler(path, delay=True);
        fh.setFormatter(logging.Formatter("%(asctime)s | %(levelname)s | %(name)s - %(message)s"));
        for lname in ["LiteLLM", "LiteLLM Router", "LiteLLM Proxy", "litellm", "httpx"] {
            lg = logging.getLogger(lname);
            lg.handlers = [fh];
            lg.propagate = False;
        }
    } except Exception {}
    return path;
}

def log_error(context: str, err: any = None) -> str {
    # Append the full story — timestamp, context, traceback — and return the
    # log path. Never raises: this runs inside except blocks.
    path = error_log_path();
    try {
        import traceback;
        import from datetime { datetime }
        stamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S");
        body = "";
        if err is not None {
            try { body = "".join(traceback.format_exception(err)); }
            except Exception { body = str(err) + "\n"; }
        }
        with open(path, "a") as f {
            f.write("[" + stamp + "] " + str(context) + "\n" + body + "\n");
        }
    } except Exception {}
    return path;
}

def friendly_llm_error(err: any, model: str = "", tier: str = "") -> str {
    # One human sentence: what went wrong with the model call and what to do
    # about it. The provider often names the model it rejected (claude-cc's
    # 404 does); prefer that over the configured name the caller passed.
    s = str(err);
    low = s.lower();
    m = re.search(r"selected model \(([^)]+)\)", s);
    name = str(m.group(1)) if m else (str(model) if model else "the configured model");
    fix = (("`sigil configure " + tier + "_model <name>`") if tier
           else "`sigil models set <tier> <name>` (see `sigil models list`)");
    hint = "  — full detail: " + error_log_path();
    if (("404" in low) or ("not_found" in low) or ("notfounderror" in low)
            or ("does not exist" in low) or ("may not exist" in low)) {
        return ("model '" + name + "' isn't available on this provider — it may be "
                + "misspelled, retired, or not offered to this account. Pick another with "
                + fix + "." + hint);
    }
    if (("401" in low) or ("invalid api key" in low) or ("authentication" in low)
            or ("api key" in low) or ("permission denied" in low)) {
        return ("the provider rejected the credentials for '" + name + "' — check the "
                + "API key (or run `claude` to sign in, for --claude mode)." + hint);
    }
    if (("429" in low) or ("rate limit" in low) or ("ratelimit" in low)
            or ("quota" in low) or ("overloaded" in low) or ("529" in low)) {
        return ("the provider is rate-limiting or overloaded right now — wait a moment "
                + "and try again." + hint);
    }
    if (("context length" in low) or ("context window" in low)
            or ("maximum context" in low) or ("context_length" in low)
            or ("too many tokens" in low)) {
        return ("the conversation no longer fits '" + name + "' — /reset the chat, or "
                + "pick a bigger-context model with " + fix + "." + hint);
    }
    if ("not found on path" in low) or ("install claude code" in low) {
        return ("the Claude Code CLI isn't installed (or not on PATH) — install it, "
                + "or run without --claude mode." + hint);
    }
    if ("timed out" in low) or ("timeout" in low) {
        return ("the call to '" + name + "' timed out — the provider may be slow or "
                + "unreachable; try again." + hint);
    }
    if (("connection refused" in low) or ("connection reset" in low)
            or ("cannot connect" in low) or ("getaddrinfo" in low)
            or ("name resolution" in low) or ("network is unreachable" in low)) {
        return ("couldn't reach the provider for '" + name + "' — check the network "
                + "(and, for a local model, that its server is running)." + hint);
    }
    return "the model call failed: " + s.split("\n")[0][:200] + hint;
}
