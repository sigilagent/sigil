"""Tests — the end-to-end LIFT. One scripted MockLLM drives every model stage
(spec loop -> spine -> the four flows); assemble + the G4 oracle then run LIVE:
the pipeline's output is a real AG-IR that must transpile + jac-check clean."""

import from jaclang.byllm.lib { MockLLM }
import from .lift_types { Rule, RuleSet, Modality, RuleKind }
import from .ir_views {
    NodeType, Owner, AgirNode, AgirEdge, WorkflowView,
    Carry, IOView, Residency, ContextView, ToolDef, KnowledgeItem, KnowledgeView, HILView
}

glob SKILL: str = """# CSV Toy
Parse the input file with the standard library.
Summarize the data in one sentence.
Always write the output as CSV with a header row.
Never use Unicode subscripts in output.
CSV rules: the output must include a header row naming every column.
""";

test "lift: SKILL.md -> spec -> spine -> views -> AG-IR -> compiled module, end to end" {
    spec = RuleSet(skill_name="csv-toy", rules=[
        Rule(id="r1", quote="Parse the input file with the standard library.", kind=RuleKind.STEP, modality=Modality.MANDATORY),
        Rule(id="r2", quote="Summarize the data in one sentence.", kind=RuleKind.STEP, modality=Modality.MANDATORY),
        Rule(id="r3", quote="Always write the output as CSV with a header row.", kind=RuleKind.IO, modality=Modality.MANDATORY),
        Rule(id="r4", quote="Never use Unicode subscripts in output.", kind=RuleKind.CONSTRAINT, modality=Modality.FORBIDDEN),
        Rule(id="r5", quote="CSV rules: the output must include a header row naming every column.", kind=RuleKind.KNOWLEDGE, modality=Modality.MANDATORY)
    ]);
    wf = WorkflowView(
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
    io = IOView(carries=[
        Carry(name="task", ctype="str", role="input"),
        Carry(name="data", ctype="str", produced_by="parse", traces_to="r1"),
        Carry(name="summary", ctype="str", produced_by="summarize", traces_to="r2"),
        Carry(name="artifact", ctype="str", produced_by="emit", traces_to="r3")
    ]);
    cx = ContextView(residency=[Residency(key="csv_rules", resident_on=["summarize"])]);
    kn = KnowledgeView(
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
    );

    # one shared mock across all three stage models; outputs pop in call order:
    # extract_round, 3x coverage_critic, workflow_view, io, context, knowledge, hil
    pin_all_lift_llms(MockLLM(model_name="mockllm", config={"outputs": [
        spec, [], [], [],
        wf,
        io, cx, kn, HILView()
    ]}));

    res = lift(SKILL, "csv-toy", parallel=False);
    assert res.spec_issues == [];
    assert res.spine_issues == [];
    assert res.assemble_issues == [];
    assert res.ok, res.compile_errors;
    assert "def run(" in res.module_src;
    assert "GEN-RAW" in res.ir_text;
}
