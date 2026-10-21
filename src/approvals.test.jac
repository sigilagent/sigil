# Tests for approvals — annex of approvals.jac (`jac test approvals.jac`).
# The policy lives on the shared graph, so every test restores what it changed.

test "pending approvals dedupe by command instead of growing without bound" {
    # Headless — a daemon-fired job, an agent retrying — nobody answers the
    # prompt, so the same blocked command comes back every run. It used to mint a
    # fresh Approval each time until the queue was unreadable.
    before = approvals_get();
    approvals_clear();
    approvals_set("allowlist", "on-miss");

    cmd = "_t_never_allowlisted --flag";
    for i in range(5) {
        d = check_exec(cmd);
        assert str(d["decision"]) == "approval-pending";
    }
    mine = [a for a in approvals_pending() if a["cmd"] == cmd];
    assert len(mine) == 1, f"expected one pending record, got {len(mine)}";

    # a DIFFERENT command is a different question
    check_exec("_t_other_command");
    names = [a["cmd"] for a in approvals_pending()];
    assert cmd in names;
    assert "_t_other_command" in names;

    approvals_clear();
    assert approvals_pending() == [];
    approvals_set(str(before["security"]), str(before["ask"]));
}

test "ask=off denies a non-allowlisted command outright, with no queue entry" {
    before = approvals_get();
    approvals_clear();
    approvals_set("allowlist", "off");
    d = check_exec("_t_denied_command");
    assert str(d["decision"]) == "deny";
    assert approvals_pending() == [], "a denial is an answer — it must not queue a question";
    approvals_set(str(before["security"]), str(before["ask"]));
}

test "an allowlisted command passes the gate" {
    before = approvals_get();
    approvals_set("allowlist", "on-miss");
    allowlist_add("_t_allowed_bin");
    d = check_exec("_t_allowed_bin --now");
    assert str(d["decision"]) == "allow";
    allowlist_remove("_t_allowed_bin");
    approvals_set(str(before["security"]), str(before["ask"]));
}

test "peek_exec answers without queueing a question nobody asked" {
    # A read-only view (`/skills`, `sigil tools`) asks what the gate WOULD say.
    # Routing that through check_exec filled the operator's pending queue every
    # time a table was rendered.
    approvals_clear();
    approvals_set("allowlist", "on-miss");
    assert peek_exec("skill:never_allowlisted") == "ask";
    assert len(approvals_pending()) == 0, str(approvals_pending());
    allowlist_add("skill:blessed");
    assert peek_exec("skill:blessed") == "allow";
    approvals_set("deny", "off");
    assert peek_exec("skill:blessed") == "deny";
    approvals_set("allowlist", "on-miss");
    approvals_clear();
}

test "allow once lets exactly one run of that command through" {
    # The console's "Allow once" button. It used to record the decision and
    # nothing read it back, so the retried command just queued again.
    before = approvals_get();
    approvals_clear();
    approvals_set("allowlist", "on-miss");

    cmd = "_t_once_only --flag";
    assert str(check_exec(cmd)["decision"]) == "approval-pending";
    r = approve_exact(cmd, "allow-once");
    assert r["ok"], str(r);
    assert str(check_exec(cmd)["decision"]) == "allow", "the grant should cover the next run";
    assert str(check_exec(cmd)["decision"]) == "approval-pending", "and only that run";
    spent = [h for h in approvals_history() if h["cmd"] == cmd];
    assert spent and (spent[0]["status"] == "used"), str(spent);

    approvals_clear();
    approvals_set(str(before["security"]), str(before["ask"]));
}

test "approve_exact answers one whole command, never a prefix" {
    before = approvals_get();
    approvals_clear();
    approvals_set("allowlist", "on-miss");

    cmd = "_t_exact_bin --one";
    check_exec(cmd);
    assert not approve_exact("_t_exact_bin", "allow-once")["ok"], "a prefix is not the command";
    bad = approve_exact(cmd, "maybe");
    assert (not bad["ok"]) and ("decision must be" in str(bad["error"]));

    # "allow-always" allowlists the pattern it is given ...
    r = approve_exact(cmd, "allow-always", "_t_exact_bin *");
    assert r["ok"] and (r["rule"] == "_t_exact_bin *"), str(r);
    assert str(check_exec("_t_exact_bin --two")["decision"]) == "allow";
    allowlist_remove("_t_exact_bin *");

    # ... or the command's first word when it is given none
    check_exec("_t_first_word --x");
    r2 = approve_exact("_t_first_word --x", "allow-always");
    assert r2["rule"] == "_t_first_word", str(r2);
    allowlist_remove("_t_first_word");

    approvals_clear();
    approvals_set(str(before["security"]), str(before["ask"]));
}
