# Tests for sigil_errors — annex of sigil_errors.jac (`jac test sigil_errors.jac`).
# The friendly mapping is pure string work; log_error is exercised against a
# throwaway SIGIL_HOME. install_error_log is NOT run here — it mutates
# process-global logging, which would eat the test runner's own output.

test "a provider 404 names the rejected model and the tier fix" {
    e = ("litellm.APIConnectionError: claude-cc: the CLI failed (404): There's an "
         + "issue with the selected model (opus-4-8). It may not exist or you may "
         + "not have access to it. Run --model to pick a different model.");
    msg = friendly_llm_error(e, "", "chat");
    assert "opus-4-8" in msg;                       # pulled from the provider text
    assert "isn't available" in msg;
    assert "sigil configure chat_model" in msg;
    assert "error.log" in msg;                      # points at the full story
    assert "Traceback" not in msg;
}

test "the wrapping APIConnectionError does not misroute a 404 to 'network'" {
    # litellm wraps provider failures in APIConnectionError — the class name
    # must not trip the network branch when the payload is a plain 404.
    msg = friendly_llm_error("litellm.APIConnectionError: NotFoundError: no model");
    assert "isn't available" in msg;
}

test "auth, rate-limit, timeout and refused-connection each get their own sentence" {
    a = friendly_llm_error("AuthenticationError: invalid x-api-key", "gpt-4o", "chat");
    assert "credentials" in a and "gpt-4o" in a;
    r = friendly_llm_error("RateLimitError: 429 too many requests");
    assert "rate-limiting or overloaded" in r;
    t = friendly_llm_error("claude chat timed out after 300s (SIGIL_CLAUDE_TIMEOUT)");
    assert "timed out" in t;
    c = friendly_llm_error("APIConnectionError: [Errno 61] Connection refused", "ollama_chat/qwen3:8b");
    assert "couldn't reach" in c and "ollama_chat/qwen3:8b" in c;
}

test "an unrecognized failure falls back to its first line, truncated" {
    msg = friendly_llm_error("SomethingOdd: weird\nsecond line never shows");
    assert "the model call failed: SomethingOdd: weird" in msg;
    assert "second line" not in msg;
}

test "without a tier the fix points at `sigil models set`" {
    msg = friendly_llm_error("404 model does not exist");
    assert "sigil models set" in msg;
}

test "log_error appends context + traceback to the sigil error log" {
    import os;
    import tempfile;
    old = os.environ.get("SIGIL_HOME");
    tmp = tempfile.mkdtemp();
    os.environ["SIGIL_HOME"] = tmp;
    try {
        p = log_error("unit test turn", ValueError("boom"));
        assert p.startswith(tmp);
        assert p.endswith(os.path.join("log", "error.log"));
        with open(p) as f { body = f.read(); }
        assert "unit test turn" in body;
        assert "boom" in body;
        # a second entry appends, never truncates
        _ = log_error("second entry", None);
        with open(p) as f { body2 = f.read(); }
        assert "unit test turn" in body2 and "second entry" in body2;
    } finally {
        if old { os.environ["SIGIL_HOME"] = old; }
        else { _ = os.environ.pop("SIGIL_HOME", None); }
    }
}
