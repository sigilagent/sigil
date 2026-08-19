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
