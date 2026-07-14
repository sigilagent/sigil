"""Total token observability — monkeypatch litellm to capture EVERY LLM call.

byLLM routes all cognition through litellm, so wrapping ``litellm.completion`` /
``acompletion`` sees every token that crosses the wire. We capture as much as each
provider exposes and record what it hides (reasoning tokens, cache tokens, cost).

Each call is appended as one JSON line to ``SIGIL_OBS`` the instant it returns
(flushed) — live-observable and crash-resilient. Streaming responses are tapped so
their tokens are captured too. Everything is best-effort and never raises into the
model call.

This module is pure Python-runtime manipulation — it patches a third-party
library's functions with ``functools.wraps`` + async closures and reassigns module
attributes. That is exactly what Jac's inline-Python (``::py::``) block is for, so
the body lives in one below; ``install`` / ``read_tail`` are still ordinary module
symbols importable from Jac (``import from .sigil_observe { read_tail }``).
"""

::py::
import functools
import json
import os
import time

_INSTALLED = False


def _num(x, default=0):
    try:
        return int(x or 0)
    except Exception:
        return default


def _extract_usage(resp) -> dict:
    u = getattr(resp, "usage", None)
    if u is None and isinstance(resp, dict):
        u = resp.get("usage")
    if u is None:
        return {}
    g = (lambda k: getattr(u, k, None) if not isinstance(u, dict) else u.get(k))
    ctd = g("completion_tokens_details")
    reasoning = 0
    if ctd is not None:
        reasoning = _num(getattr(ctd, "reasoning_tokens", None) if not isinstance(ctd, dict) else ctd.get("reasoning_tokens"))
    return {
        "prompt_tokens": _num(g("prompt_tokens")),
        "completion_tokens": _num(g("completion_tokens")),
        "total_tokens": _num(g("total_tokens")),
        "cache_creation_tokens": _num(g("cache_creation_input_tokens")),
        "cache_read_tokens": _num(g("cache_read_input_tokens")),
        "reasoning_tokens": reasoning,
    }


def _extract_message(resp) -> dict:
    try:
        choice = resp.choices[0]
        msg = getattr(choice, "message", None) or {}
        get = (lambda k: msg.get(k) if isinstance(msg, dict) else getattr(msg, k, None))
        content = get("content") or ""
        reasoning = get("reasoning_content")
        tcs = get("tool_calls") or []
        tool_calls = []
        for t in tcs:
            fn = (t.get("function") if isinstance(t, dict) else getattr(t, "function", None)) or {}
            name = fn.get("name") if isinstance(fn, dict) else getattr(fn, "name", None)
            tool_calls.append(name or "?")
        return {
            "content": (content or "")[:600],
            "content_len": len(content or ""),
            "reasoning_content": (reasoning or "")[:600] if reasoning else None,
            "tool_calls": tool_calls,
        }
    except Exception:
        return {"content": "", "content_len": 0, "reasoning_content": None, "tool_calls": []}


def _record(path, sig, kwargs, resp, duration_ms, error=None):
    try:
        import litellm
        cost = None
        try:
            cost = litellm.completion_cost(completion_response=resp) if resp is not None else None
        except Exception:
            cost = None
        msgs = kwargs.get("messages", []) or []
        rec = {
            "ts": time.time(),
            "signature": sig,
            "model": kwargs.get("model", "?"),
            "message_count": len(msgs),
            "duration_ms": round(duration_ms, 1),
            "cost_usd": cost,
            "error": (str(error)[:300] if error else None),
        }
        rec.update(_extract_usage(resp) if resp is not None else {})
        rec.update(_extract_message(resp) if resp is not None else {})
        with open(path, "a") as f:
            f.write(json.dumps(rec) + "\n")
            f.flush()
    except Exception:
        pass


def install(stream_path: str = "", sig: str = "") -> bool:
    """Patch litellm.completion / acompletion to record every call to stream_path."""
    global _INSTALLED
    if _INSTALLED or not stream_path:
        return False
    try:
        import litellm
    except Exception:
        return False
    os.makedirs(os.path.dirname(stream_path) or ".", exist_ok=True)

    _orig = litellm.completion

    @functools.wraps(_orig)
    def _wrapped(*a, **kw):
        t0 = time.time()
        try:
            resp = _orig(*a, **kw)
        except Exception as e:
            _record(stream_path, sig, kw, None, (time.time() - t0) * 1000, error=e)
            raise
        _record(stream_path, sig, kw, resp, (time.time() - t0) * 1000)
        return resp

    litellm.completion = _wrapped

    if hasattr(litellm, "acompletion"):
        _aorig = litellm.acompletion

        @functools.wraps(_aorig)
        async def _awrapped(*a, **kw):
            t0 = time.time()
            try:
                resp = await _aorig(*a, **kw)
            except Exception as e:
                _record(stream_path, sig, kw, None, (time.time() - t0) * 1000, error=e)
                raise
            _record(stream_path, sig, kw, resp, (time.time() - t0) * 1000)
            return resp

        litellm.acompletion = _awrapped

    _INSTALLED = True
    return True


def read_tail(stream_path: str, n: int = 200) -> list[dict]:
    """Return the last n observability records (for the server endpoint)."""
    try:
        with open(stream_path) as f:
            lines = f.readlines()[-n:]
    except OSError:
        return []
    out = []
    for ln in lines:
        ln = ln.strip()
        if not ln:
            continue
        try:
            out.append(json.loads(ln))
        except Exception:
            continue
    return out
::py::
