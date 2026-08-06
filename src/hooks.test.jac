# Tests for hooks — annex of hooks.jac (`jac test hooks.jac`).
#
# hooks.jac documents an OpenClaw-shaped lifecycle bus, and for a long time four
# of its named events had no call site anywhere in the codebase: registering a
# hook for `gateway_start`, `session_start`, `before_tool` or `after_tool` was
# registering for something that never happened. These tests pin the wiring so a
# refactor cannot quietly unhook them again. The call sites themselves are
# asserted in the annexes of the modules that own them (sigil_sessions,
# sigil_workspace) — importing them here would be a cycle, since both import
# this module.

def _fired_count(name: str) -> int {
    for h in hook_list() { if h["name"] == name { return int(h["fired"]); } }
    return -1;
}

test "a note hook fires for its own event and no other" {
    hook_remove("_t_hook_a");
    hook_add("_t_hook_a", "_t_event_a", "note", "observed");
    out = fire_hooks("_t_event_a", "payload");
    assert len(out) == 1;
    assert str(out[0]["hook"]) == "_t_hook_a";
    assert _fired_count("_t_hook_a") == 1;

    fire_hooks("_t_event_b", "payload");
    assert _fired_count("_t_hook_a") == 1, "a hook must not fire for another event";

    hook_enable("_t_hook_a", False);
    fire_hooks("_t_event_a", "payload");
    assert _fired_count("_t_hook_a") == 1, "a disabled hook must not fire";
    hook_remove("_t_hook_a");
}

test "a hook that raises does not take the caller down with it" {
    # Hooks run inside a solve, a tool call and a channel reply. One bad shell
    # action must not break the thing it was observing.
    hook_remove("_t_bad_hook");
    hook_add("_t_bad_hook", "_t_event_bad", "shell", "exit 3");
    out = fire_hooks("_t_event_bad", "payload");
    assert len(out) == 1, "a failing hook still reports a result";
    hook_remove("_t_bad_hook");
}
