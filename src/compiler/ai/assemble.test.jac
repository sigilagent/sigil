"""Tests — Assemble. Pure-code join checks (reflexive 5d, cross-refs,
prose-pointer precheck) plus the money test: the assembled IR round-trips LIVE
through the mechanical half + jac check."""

import from .lift_types { Modality, RuleKind }
import from .spec_loop { Rule, RuleSet }
import from .ir_views { NodeType, Owner }
import from .workflow { AgirNode, AgirEdge, WorkflowView }
import from .flows { Carry, IOView, Residency, ContextView, ToolDef, KnowledgeItem, KnowledgeView, HILView, HILPoint, ViewBundle }
import from .gates { compile_gate }

def _spec() -> RuleSet {
    return RuleSet(skill_name="csv-toy", rules=[
        Rule(id="r1", quote="Parse the input file with the standard library.", kind=RuleKind.STEP, modality=Modality.MANDATORY),
        Rule(id="r2", quote="Summarize the data in one sentence.", kind=RuleKind.STEP, modality=Modality.MANDATORY),
        Rule(id="r3", quote="Always write the output as CSV with a header row.", kind=RuleKind.IO, modality=Modality.MANDATORY),
        Rule(id="r4", quote="Never use Unicode subscripts in output.", kind=RuleKind.CONSTRAINT, modality=Modality.FORBIDDEN),
        Rule(id="r5", quote="CSV rules: the output must include a header row naming every column.", kind=RuleKind.KNOWLEDGE, modality=Modality.MANDATORY)
    ]);
}

def _wf() -> WorkflowView {
    return WorkflowView(
        nodes=[
            AgirNode(id="parse", ntype=NodeType.SENSE, owner=Owner.CODE,
                     doc="Parse the input file.", reads=["task"], writes=["data"], traces_to=["r1"]),
            AgirNode(id="summarize", ntype=NodeType.GEN_RAW, owner=Owner.MODEL,
                     doc="Summarize the data in one sentence.",
                     reads=["data", "csv_rules"], writes=["summary"], traces_to=["r2"]),
            AgirNode(id="emit", ntype=NodeType.ACT, owner=Owner.CODE, surface="artifact",
                     doc="Write the output as CSV with a header row.",
                     reads=["data", "summary"], writes=["artifact"], traces_to=["r3"]),
            AgirNode(id="done", ntype=NodeType.TERMINAL)
        ],
        edges=[
            AgirEdge(src="parse", dst="summarize", modality=Modality.MANDATORY, traces_to="r1"),
            AgirEdge(src="summarize", dst="emit", modality=Modality.MANDATORY, traces_to="r2"),
            AgirEdge(src="emit", dst="done", modality=Modality.MANDATORY, traces_to="r3")
        ],
        spawn_note="sequential: each step consumes the prior step's output",
        constraints=["r4: Never use Unicode subscripts in output."]
    );
}

def _views() -> ViewBundle {
    return ViewBundle(
        io=IOView(carries=[
            Carry(name="task", ctype="str", role="input"),
            Carry(name="data", ctype="str", produced_by="parse", traces_to="r1"),
            Carry(name="summary", ctype="str", produced_by="summarize", traces_to="r2"),
            Carry(name="artifact", ctype="str", produced_by="emit", traces_to="r3")
        ], artifact_note="emit writes the deliverable CSV (path task-variant)"),
        ctxv=ContextView(residency=[Residency(key="csv_rules", resident_on=["summarize"])]),
        kn=KnowledgeView(
            tools=[
                ToolDef(name="parse_input", sig="(task) -> str", surface="SENSE", serves=["parse"],
                        body="return \"col_a,col_b\\n1,2\\n3,4\"", traces_to="r1"),
                ToolDef(name="write_csv", sig="(data, summary) -> path", surface="ACT·artifact", serves=["emit"],
                        body="with open(\"out.csv\", \"w\") as f:\n    f.write(str(data))\nreturn \"out.csv\"",
                        traces_to="r3")
            ],
            knowledge=[KnowledgeItem(key="csv_rules",
                content="CSV rules: the output must include a header row naming every column.",
                resident_on=["summarize"], traces_to="r5")]
        ),
        hil=HILView()
    );
}

test "a lossless join assembles with no issues" {
    res = assemble(_spec(), _wf(), _views(), "csv-toy");
    assert res.issues == [];
    assert "GEN-RAW" in res.ir_text;
    assert "tools:" in res.ir_text;
    assert "knowledge:" in res.ir_text;
    assert "NEVER violate" in res.ir_text;   # the FORBIDDEN constraint rides the Mind node's doc
}

# Folding EVERY constraint into EVERY Mind slot put ~30 unrelated prohibitions on
# each one — a decl-syntax rule lecturing the node that curls an endpoint. A
# prohibition rides only the slots it governs, and one scoped to a code node
# escalates to the model slot that PRODUCES what that node consumes.
test "a prohibition is scoped to the slots it governs, not sprayed on all of them" {
    wf = _wf();
    wf.nodes.append(AgirNode(id="pick_name", ntype=NodeType.GEN_ENUM, owner=Owner.MODEL,
                             doc="Choose a short label for the run.",
                             reads=["task"], writes=["label"], traces_to=["r2"]));
    views = _views();
    views.io.carries.append(Carry(name="label", ctype="str", produced_by="pick_name"));
    res = assemble(_spec(), wf, views, "csv-toy");
    ir = res.ir_text;
    # `summarize` writes the summary that `emit` outputs — the Unicode-subscript
    # prohibition binds there...
    idx_sum = ir.find("id: summarize");
    idx_pick = ir.find("id: pick_name");
    assert idx_sum >= 0 and idx_pick >= 0;
    seg_sum = ir[idx_sum:idx_pick] if idx_sum < idx_pick else ir[idx_sum:];
    assert "NEVER violate" in seg_sum;
    # ...and NOT on a slot that has nothing to do with the output
    seg_pick = ir[idx_pick:] if idx_pick > idx_sum else ir[idx_pick:idx_sum];
    assert "NEVER violate" not in seg_pick;
}

test "an unplaceable constraint stays global and is reported, never dropped" {
    wf = _wf();
    wf.constraints = ["r4: Zzzqqx yyywwv."];   # shares no token with any node
    res = assemble(_spec(), wf, _views(), "csv-toy");
    assert "NEVER violate" in res.ir_text;     # never silently dropped
    assert len([i for i in res.issues if "could not be scoped" in i]) == 1;
}

test "the assembled IR round-trips LIVE through the mechanical half" {
    res = assemble(_spec(), _wf(), _views(), "csv-toy");
    v = compile_gate(res.ir_text, "csv_toy");
    assert v.ok, v.errors;
    assert "def run(" in v.module_src;
}

test "reflexive 5d: a rule no view consumes is a dropped lane" {
    vb = _views();
    vb.kn.knowledge = [];   # r5 (KNOWLEDGE) now has no consumer
    res = assemble(_spec(), _wf(), vb, "csv-toy");
    assert len([i for i in res.issues if "'r5'" in i and "5d" in i]) == 1;
}

test "cross-ref: an orphan carry and an unknown producer are flagged" {
    vb = _views();
    vb.io.carries.append(Carry(name="ghost", produced_by="nowhere"));
    res = assemble(_spec(), _wf(), vb, "csv-toy");
    assert len([i for i in res.issues if "'ghost'" in i and "unknown node" in i]) == 1;
}

test "prose-pointer precheck: an unembodied tool is flagged" {
    vb = _views();
    vb.kn.tools.append(ToolDef(name="magic", sig="(x) -> y", serves=["parse"]));
    res = assemble(_spec(), _wf(), vb, "csv-toy");
    assert len([i for i in res.issues if "'magic'" in i and "prose-pointer" in i]) == 1;
}

test "a HIL point injects a real ask_user gate: SENSE served + Mind autonomy belt" {
    spec = _spec(); wf = _wf(); vb = _views();
    # gate the model Mind node (summarize) and pretend parse waits on a human
    vb.hil = HILView(points=[
        HILPoint(node="summarize", kind="CONFIRM", prompt="proceed with this summary?"),
        HILPoint(node="parse", kind="INPUT", prompt="which file should I parse?")
    ]);
    res = assemble(spec, wf, vb, "csv-toy");
    assert "ask_user_summarize" in res.ir_text;
    assert "ask_user_parse" in res.ir_text;
    assert "_ask_user(" in res.ir_text;           # embodied body, not a pointer
    v = compile_gate(res.ir_text, "csv_toy_hil");
    assert v.ok, v.errors;
    assert "_ask_user" in v.module_src;           # the runtime channel rode into the module
}

test "a HIL gate asks the RUNTIME question, falling back to the lifted text" {
    spec = _spec(); wf = _wf(); vb = _views();
    vb.hil = HILView(points=[
        HILPoint(node="parse", kind="INPUT", prompt="which file should I parse?")
    ]);
    res = assemble(spec, wf, vb, "csv-toy");
    v = compile_gate(res.ir_text, "csv_toy_hil_q");
    assert v.ok, v.errors;
    # the `prompt` argument must reach _ask_user — a gate the human cannot read
    # is not a gate. The lifted text remains as the no-runtime-question fallback.
    assert 'q = str(prompt or "").strip()' in v.module_src;
    assert '_ask_user(("INPUT: " + q) if q else' in v.module_src;
    assert "which file should I parse?" in v.module_src;
}

test "a HIL point with no lifted prompt still asks the model's question" {
    spec = _spec(); wf = _wf(); vb = _views();
    # brainstorming's clarify loop lifts with an EMPTY prompt — the case that
    # produced a bare "INPUT:" with no question in a live run.
    vb.hil = HILView(points=[HILPoint(node="parse", kind="INPUT", prompt="")]);
    res = assemble(spec, wf, vb, "csv-toy");
    v = compile_gate(res.ir_text, "csv_toy_hil_empty");
    assert v.ok, v.errors;
    assert '_ask_user(("INPUT: " + q) if q else "INPUT:")' in v.module_src;
}
