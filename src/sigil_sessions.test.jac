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

test "a channel's chat history persists per conversation, bounded, and resets on /new" {
    chat_history_reset("_t_chat", "user:1", "per-peer");
    assert chat_history("_t_chat", "user:1", "per-peer") == [];
    turns = [{"role": "user", "content": "m" + str(i)} for i in range(40)];
    assert chat_history_save("_t_chat", "user:1", "per-peer", turns) == 32, "kept bounded";
    got = chat_history("_t_chat", "user:1", "per-peer");
    assert got[-1]["content"] == "m39", str(got[-1]);
    # another peer on a per-peer channel is a separate conversation
    assert chat_history("_t_chat", "user:2", "per-peer") == [];
    chat_history_reset("_t_chat", "user:1", "per-peer");
    assert chat_history("_t_chat", "user:1", "per-peer") == [];
}
