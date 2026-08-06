# Tests for sigil_sessions — annex of sigil_sessions.jac.
# Transcript scoping and the lifecycle event a transcript beginning fires.

test "session_start fires when a transcript begins" {
    # `session_start` is a documented lifecycle event that had no call site
    # anywhere: registering a hook for it registered for something that never
    # happened. A transcript beginning is the event.
    import from .hooks { hook_add, hook_remove, hook_list }
    hook_remove("_t_session_hook");
    hook_add("_t_session_hook", "session_start", "note", "seen");
    before = 0;
    for h in hook_list() { if h["name"] == "_t_session_hook" { before = int(h["fired"]); } }
    _fire_session_start("chan:peer", "new transcript");
    after = -1;
    for h in hook_list() { if h["name"] == "_t_session_hook" { after = int(h["fired"]); } }
    assert after == before + 1;
    hook_remove("_t_session_hook");
}
