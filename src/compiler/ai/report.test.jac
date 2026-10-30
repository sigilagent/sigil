"""report — severity classification, the four-state status, the explain note."""

import os;
import from .ir_views { LiftResult }

test "severity: only crash/mandate gates are errors; audits are warnings" {
    assert classify("G4") == "error";
    assert classify("G6_PAR") == "error";
    assert classify("G2_ARTIFACT") == "error";
    assert classify("G3_HIL") == "error";
    assert classify("G5") == "warn";
    assert classify("G2") == "warn";
    assert classify("spec") == "warn";
    assert classify("assemble") == "warn";
}

test "G6_ENV is an install-time warning by default, hard only on opt-in" {
    prev = os.environ.get("SIGIL_G7_HARD", "");
    os.environ["SIGIL_G7_HARD"] = "";
    assert classify("G6_ENV") == "warn";
    os.environ["SIGIL_G7_HARD"] = "1";
    assert classify("G6_ENV") == "error";
    os.environ["SIGIL_G7_HARD"] = prev;
}

test "status: failed only when no module; findings degrade; fixes alone are fixed" {
    assert status_of(False, [], [], []) == "failed";
    assert status_of(True, [finding("G2", "G2: rule 'r1' realized MONOLITHICALLY")], [], []) == "degraded";
    assert status_of(True, [], ["lane: minted input carry 'x'"], []) == "fixed";
    assert status_of(True, [], [], ["repair_ir attempt 1: fixed"]) == "fixed";
    assert status_of(True, [], [], []) == "clean";
}

test "auto_gate reads the message's own prefix" {
    assert auto_gate("G2: rule 'r1'...") == "G2";
    assert auto_gate("tool 'x' has neither body nor command") == "assemble";
    assert auto_gate("something", "G5") == "G5";
}

test "a fix note naming the same quoted subject supersedes the issue" {
    fixes = ["lane: minted input carry 'user_request' (node 'n_a' read it but no lane existed)"];
    assert resolved_by("node 'n_a' reads 'user_request' which is neither a carry nor knowledge (no lane)", fixes);
    # a different reader of the SAME minted lane is also resolved
    assert resolved_by("node 'n_x' reads 'user_request' which is neither a carry nor knowledge (no lane)", fixes);
    assert not resolved_by("node 'n_x' reads 'other_lane' which is neither a carry nor knowledge (no lane)", fixes);
    assert not resolved_by("no quoted subject at all", fixes);
}

test "explain: a failure names what was tried and the next step" {
    lr = LiftResult(status="failed", compile_errors="jac check: 2 error(s)\nerror[E1001] ...",
                    repairs=["repair_ir attempt 1: still failing", "repair_ir attempt 2: still failing"]);
    e = explain(lr);
    assert "FAILED" in e;
    assert "2 attempt(s)" in e;
    assert "sigil gate" in e;
    assert "SIGIL_CLAUDE_REPAIR" in e;
}

test "explain: a degraded lift reads as runnable with findings, fixes first-class" {
    lr = LiftResult(status="degraded", ok=False,
                    findings=[finding("G2", "G2: rule 'r2' realized MONOLITHICALLY"),
                              finding("G4", "G4: carry 'rows' is declared 'str' but tool 't' requires 'list'")],
                    fixes=["pointer: knowledge 'forms' pointed at FORMS.md — embodied 812 chars verbatim"]);
    e = explain(lr);
    assert "RUNNABLE" in e;
    assert "fixed along the way" in e;
    # errors sort above warnings
    assert e.find("G4:") < e.find("G2:");
}
