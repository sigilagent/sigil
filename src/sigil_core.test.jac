# Tests for sigil_core — annex of sigil_core.jac (`jac test sigil_core.jac`).

import from .sigil_runtime { _lock_acquire, _lock_release }

# --- the cold-graph seed ----------------------------------------------------
# Waking an EMPTY store used to leave the seed dirty for the life of the
# process — jac commits on exit, so `sigil chat` sat on a brand-new root anchor
# for as long as the REPL was open. On a store with real row locks every
# sibling process blocks on that anchor, which is how the auto-started
# scheduler broke the first `sigil chat` on a fresh checkout (postgres lock
# timeout on the anchors index, 60s in). The seed now runs through graph_write:
# locked, and committed on the spot.
#
# What that does NOT buy is cross-process uniqueness — a process that already
# materialized root's edges cannot see another's seed even while holding the
# lock, so two genuinely simultaneous cold starts still seed twice (unchanged
# by this, and unfixable from here: jac exposes no anchor re-read). These cover
# the parts that do hold.

test "the seed adopts the Soul on the graph instead of adding another" {
    first = awaken();
    souls = len([root -->[?:Soul]]);
    assert souls == 1;
    # what any later caller runs once it has the lock: the graph is no longer
    # cold, and the read inside the critical section has to see that.
    again = _seed_soul();
    assert len([root -->[?:Soul]]) == souls;
    assert again == first;
}

test "awaken leaves no critical section behind" {
    # The lock covers one seed, not the length of a command — a `compile` that
    # woke the agent and then ran models for a minute would otherwise block
    # every other process's write for that minute.
    awaken();
    h = _lock_acquire(timeout_s=2.0);
    assert h is not None;
    _lock_release(h);
}

# --- why a run failed ---------------------------------------------------------
# The trace used to say "small-model FAIL" and drop the run's stderr, so the
# chat agent could not tell a crash from an empty search (hackernews_chat_summary).
test "fail_reason names the exception and the walker step it died in" {
    err = "Traceback (most recent call last):\n  File \"/x/hn_v5.jac\", line 2050, in n_prioritize\n    self.ordered_records = list(...)\n  File \"/x/hn_v5.jac\", line 144, in order_records\nAttributeError: 'str' object has no attribute 'get'\n";
    why = fail_reason({"ok": False, "report": "", "error": err});
    assert why.startswith("AttributeError: 'str' object has no attribute 'get'"), why;
    assert why.endswith("(in step prioritize)"), why;
    assert fail_reason({"ok": False, "report": "", "error": ""}) == "the run returned an empty report";
    assert fail_reason({"ok": False, "report": "INCOMPLETE: no log", "error": ""}).startswith("INCOMPLETE");
    assert fail_reason({"ok": False, "report": "", "error": "timeout after 1800s"}) == "timeout after 1800s";
}

# --- automatic rewrites -------------------------------------------------------
# A 30-minute cron job rewrote hackernews_topic_log on nearly every run (v46 ->
# v130 in four days): a dropped connection triggered a mutate, and an honest
# "nothing new" run graded low and triggered a relearn.
test "a dropped connection or timeout is transient; a code error is not" {
    assert transient_failure({"error": "litellm.APIConnectionError: chatgpt: the stream ended before the reply was complete"});
    assert transient_failure({"error": "timeout after 1800s"});
    assert transient_failure({"error": "chatgpt: the connection dropped (RemoteProtocolError: peer closed connection) (connection dropped; 4 resends also failed)"});
    assert transient_failure({"error": "openai.RateLimitError: Error code: 429"});
    assert not transient_failure({"error": "AttributeError: 'str' object has no attribute 'get'"});
    assert not transient_failure({"error": "", "report": "retrieved 502 candidates"});
    assert not transient_failure({"error": "File \"x.jac\", line 502, in n_search\nKeyError: 'hits'"});
}

test "a fresh automatic rewrite is not rewritten again inside the cooldown" {
    fresh = TaskGraph(signature="s", intent="i", agir="", module="", version=7, origin="relearn", born_ms=now_ms() - 60000);
    assert rewrite_blocked(fresh) != "";
    old = TaskGraph(signature="s", intent="i", agir="", module="", version=7, origin="mutation", born_ms=now_ms() - 25 * 3600000);
    assert rewrite_blocked(old) == "";
    compiled = TaskGraph(signature="s", intent="i", agir="", module="", version=1, origin="compiled-skill-raise2", born_ms=now_ms());
    assert rewrite_blocked(compiled) == "", "a compile the person asked for may still be repaired";
    legacy = TaskGraph(signature="s", intent="i", agir="", module="", version=9, origin="relearn");
    assert rewrite_blocked(legacy) == "", "versions from before born_ms was tracked are not held";
}
