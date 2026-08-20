# Tests for sigil_skill_tools — annex (`jac test sigil_skill_tools.jac`).
# Covers the two gates (policy filter, approval), the tool objects handed to
# byLLM, and the manifest a subprocess run gets. No model calls, no network:
# every skill here is a TaskGraph on the test graph with no module behind it,
# so nothing is ever actually executed.

import from .sigil_core { awaken, Registry, TaskGraph, configure, Anchored, Crystallized }
import from .approvals { approvals_set, approvals_get, allowlist_add, approvals_clear, _policy }
import from .sigil_workspace { set_approver, drain_trace }

def _seed(sig: str, intent: str = "", module: str = "", runs: int = 0, ok: int = 0) -> TaskGraph {
    # Hang one compiled skill off the live Registry so library() sees it.
    awaken();
    regs = [root -->][?:Registry];
    reg = regs[0] if regs else Registry();
    if not regs { root +>:Anchored:+> reg; }
    tg = TaskGraph(signature=sig, intent=intent, agir="", module=module,
                   version=1, runs=runs, successes=ok);
    reg +>:Crystallized:+> tg;
    return tg;
}

def _clear_skills() -> None {
    regs = [root -->][?:Registry];
    if not regs { return; }
    for tg in [regs[0] -->][?:TaskGraph] { del tg; }
}

test "a skill's tool name is the one mcp-serve publishes outward" {
    # One skill, one name, whichever side of the harness is calling — that is
    # what lets `configure tool_deny skill_clean_csv` mean the same thing in
    # chat, in a sub-agent, and over the MCP wire.
    assert tool_name("clean_csv") == "skill_clean_csv";
    assert tool_name("a b/c") == "skill_a_b_c";
    assert len(tool_name("x" * 200)) <= 64;
}

test "the description leads with the intent and carries the run record" {
    d = describe({"signature": "clean_csv", "intent": "Clean a messy CSV.",
                  "version": 2, "runs": 5, "successes": 4});
    assert d.startswith("Clean a messy CSV."), d;
    assert "4/5 runs succeeded" in d, d;
    assert "v2" in d, d;
    fresh = describe({"signature": "new_one", "intent": "Do a thing.", "runs": 0});
    assert "not yet run" in fresh, fresh;
}

test "a skill with no intent still describes itself by name" {
    d = describe({"signature": "odd_one", "intent": "", "runs": 0});
    assert "odd_one" in d, d;
}

test "an empty library is an empty tool list, not a crash" {
    _clear_skills();
    assert skill_tools() == [];
    assert skill_tool_index() == [];
    assert skill_manifest() == "";
}

test "every compiled skill becomes one byLLM tool, named and schematized" {
    _clear_skills();
    _seed("clean_csv", "Clean a messy CSV into a tidy one.", "/tmp/crystallized/clean_csv_v1.jac");
    tools = skill_tools();
    assert len(tools) == 1, str(len(tools));
    t = tools[0];
    assert t.get_name() == "skill_clean_csv", t.get_name();
    schema = t.get_json_schema();
    fn = schema["function"];
    assert fn["name"] == "skill_clean_csv";
    assert "Clean a messy CSV" in str(fn["description"]);
    # the model needs somewhere to put the task, or the tool is a button with no label
    assert "task" in dict(fn["parameters"]["properties"]);
    _clear_skills();
}

test "tool_deny keeps a skill out of the list entirely — not just out of the call" {
    _clear_skills();
    _seed("clean_csv", "Clean a CSV.", "/tmp/m1.jac");
    _seed("draft_notes", "Draft notes.", "/tmp/m2.jac");
    configure("tool_deny", "skill_clean_csv");
    names = [str(r["tool"]) for r in skill_tool_index()];
    assert "skill_draft_notes" in names, str(names);
    assert "skill_clean_csv" not in names, str(names);
    # and the runner agrees with the list it published
    out = run_skill("clean_csv", "clean something");
    assert "no compiled skill" in out, out;
    assert "Nothing was run" in out, out;
    configure("tool_deny", "");
    _clear_skills();
}

test "tool_allow is an allow-LIST: a skill outside it is not offered" {
    _clear_skills();
    _seed("clean_csv", "Clean a CSV.", "/tmp/m1.jac");
    _seed("draft_notes", "Draft notes.", "/tmp/m2.jac");
    configure("tool_allow", "skill_draft_notes");
    names = [str(r["tool"]) for r in skill_tool_index()];
    assert names == ["skill_draft_notes"], str(names);
    configure("tool_allow", "");
    _clear_skills();
}

test "an un-approved skill is BLOCKED, and nothing runs" {
    # Nobody at the prompt (headless: a daemon tick, a channel message) means the
    # answer is no, and the question goes on the operator's pending queue.
    _clear_skills();
    _seed("clean_csv", "Clean a CSV.", "/tmp/m1.jac");
    approvals_clear();
    approvals_set("allowlist", "on-miss");
    set_approver(None);
    out = run_skill("clean_csv", "clean messy.csv");   # returns AT the gate; nothing executes
    assert out.startswith("BLOCKED"), out;
    assert "sigil approvals approve" in out, out;
    pend = [a.cmd for a in [_policy() -->[?:Approval]] if a.status == "pending"];
    assert "skill:clean_csv" in pend, str(pend);
    approvals_clear();
    _clear_skills();
}

test "the operator's yes allowlists the SKILL, so it is asked once" {
    # `gate` rather than `run_skill`: what is under test is the decision, and
    # letting the run proceed would put a model call inside the test suite.
    approvals_clear();
    approvals_set("allowlist", "on-miss");
    asked: list = [];
    def _yes(subject: str) -> bool { asked.append(str(subject)); return True; }
    set_approver(_yes);
    assert gate("clean_csv", "clean messy.csv") == "";
    assert len(asked) == 1, str(asked);
    assert str(asked[0]).startswith("skill:clean_csv"), str(asked);
    assert "skill:clean_csv" in [str(x) for x in list(approvals_get()["allowlist"])];
    # second call: already allowlisted, so the operator is not asked again
    assert gate("clean_csv", "clean another.csv") == "";
    assert len(asked) == 1, str(asked);
    set_approver(None);
    approvals_clear();
}

test "a no from the operator blocks the run and never reaches the skill" {
    approvals_clear();
    approvals_set("allowlist", "on-miss");
    def _no(subject: str) -> bool { return False; }
    set_approver(_no);
    out = gate("draft_notes", "draft something");
    assert out.startswith("BLOCKED"), out;
    assert "Nothing was run" in out, out;
    set_approver(None);
    approvals_clear();
}

test "exec.security=deny denies skills too, and says which policy did it" {
    _clear_skills();
    _seed("clean_csv", "Clean a CSV.", "/tmp/m1.jac");
    approvals_set("deny", "off");
    out = run_skill("clean_csv", "clean messy.csv");
    assert out.startswith("DENIED"), out;
    assert "Nothing was run" in out, out;
    approvals_set("allowlist", "on-miss");
    approvals_clear();
    _clear_skills();
}

test "an unknown signature is a normal answer, not an exception" {
    _clear_skills();
    out = run_skill("not_a_skill", "do something");
    assert "no compiled skills yet" in out, out;
    _seed("clean_csv", "Clean a CSV.", "/tmp/m1.jac");
    out2 = run_skill("not_a_skill", "do something");
    assert "no compiled skill 'not_a_skill'" in out2, out2;
    assert "clean_csv" in out2, out2;      # what it could have called instead
    _clear_skills();
}

test "the manifest hands a run its SIBLINGS, by module stem, never itself" {
    import json;
    _clear_skills();
    _seed("clean_csv", "Clean a CSV.", "/tmp/crystallized/clean_csv_v1.jac");
    _seed("draft_notes", "Draft notes.", "/tmp/crystallized/draft_notes_v2.jac");
    rows = json.loads(skill_manifest("clean_csv"));
    assert len(rows) == 1, str(rows);
    assert rows[0]["signature"] == "draft_notes";
    assert rows[0]["name"] == "skill_draft_notes";
    # the stem, not the path: the artifact imports `crystallized.<stem>`
    assert rows[0]["module"] == "draft_notes_v2", str(rows[0]);
    _clear_skills();
}

test "a skill with no module on disk is not offered to a subprocess run" {
    import json;
    _clear_skills();
    _seed("clean_csv", "Clean a CSV.", "");
    assert skill_manifest() == "";
    _clear_skills();
}

test "the progress tail turns node events into live skill trace lines" {
    # The compiled module appends one JSON line per node entry; the tail is what
    # makes a multi-minute procedure visible instead of a frozen spinner.
    import os;
    import tempfile;
    d = tempfile.mkdtemp();
    p = os.path.join(d, "agir.progress");
    with open(p, "w") as f {
        f.write('{"node": "fetch_top_ids", "t": 1}' + chr(10) + '{"node": "judge_relevance", "t": 2}' + chr(10));
    }
    drain_trace();
    _tail_progress(p, {"done": True});
    tr = drain_trace();
    joined = " | ".join([str(t["detail"]) for t in tr if str(t["tool"]) == "skill"]);
    assert "fetch_top_ids" in joined, joined;
    assert "judge_relevance" in joined, joined;
}
