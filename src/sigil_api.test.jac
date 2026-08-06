# Tests for sigil_api — annex of sigil_api.jac.
#
# The seam every HTTP endpoint resolves through. These assert the two properties
# that decide whether the Observatory shows the real agent or a convincing empty
# one: the child gets an environment that resolves the project's store, and a
# failure is reported as a failure rather than as a plausible blank answer.

import os;

test "the child environment drops the runtime wiring it must not inherit" {
    # The bug this exists to prevent: the server exports its own jac runtime
    # settings, a child inherited them, resolved the SERVER's store, and answered
    # from an empty graph — with the proxy working perfectly the whole time.
    os.environ["JAC_TEST_LEAK"] = "server-value";
    os.environ["JACLANG_TEST_LEAK"] = "server-value";
    os.environ["SIGIL_TEST_KEEP"] = "mine";
    env = child_env();
    assert "JAC_TEST_LEAK" not in env, "a JAC* var must not reach the child";
    assert "JACLANG_TEST_LEAK" not in env;
    assert str(env.get("SIGIL_TEST_KEEP")) == "mine", "the agent's own settings must survive";
    assert str(env.get("PATH") or ""), "the child still needs a PATH to find jac";
    os.environ.pop("JAC_TEST_LEAK", None);
    os.environ.pop("JACLANG_TEST_LEAK", None);
    os.environ.pop("SIGIL_TEST_KEEP", None);
}

test "the child is marked so a proxy cannot proxy to itself" {
    env = child_env();
    assert str(env.get(CHILD_ENV)) == "1";
    was = os.environ.get(CHILD_ENV);
    os.environ[CHILD_ENV] = "1";
    assert in_child();
    r = api_call("soul", {});
    assert not r["ok"], "inside the child, api_call must refuse rather than recurse";
    assert "recurse" in str(r["error"]);
    if was is None { os.environ.pop(CHILD_ENV, None); } else { os.environ[CHILD_ENV] = was; }
}

test "an unknown endpoint fails loudly instead of answering blank" {
    # An endpoint that silently returns an empty result is exactly how "the
    # Observatory works" survived this long. A failure must look like one.
    r = report_for("_t_no_such_api", {});
    got = dict(r);
    assert not got["ok"];
    assert "unknown api" in str(got["error"]);
    assert str(got["hint"]), "a failure should say what was being attempted";
}

test "a real endpoint answers from the project's graph, not the caller's" {
    # The end-to-end assertion: this runs a subprocess against the real store.
    soul = report_for("soul", {});
    got = dict(soul);
    assert "name" in got, f"expected a soul, got {got}";
    assert "skills" in got;
    assert int(got["skills"]) >= 0;
}
