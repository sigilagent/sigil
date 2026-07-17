"""Scenario — lift() end-to-end + view repair, MockLLM-scripted with LIVE
assemble/G4. See workflow_loop.jac for why this runs under `jac run`.
Exits nonzero on failure."""

import from jaclang.byllm.lib { MockLLM }
import from src.compiler.ai.lift_types { Modality, RuleKind, Cohesion }
import from src.compiler.ai.spec_loop { Rule, RuleSet }
import from src.compiler.ai.ir_views { NodeType, Owner }
import from src.compiler.ai.workflow { AgirNode, AgirEdge, WorkflowView }
import from src.compiler.ai.flows {
    Carry, IOView, Residency, ContextView, ToolDef, KnowledgeItem, KnowledgeView, HILView
}
import from src.compiler.ai.lift { lift, pin_all_lift_llms }

glob SKILL: str = """# CSV Toy
Parse the input file with the standard library.
Summarize the data in one sentence.
Always write the output as CSV with a header row.
Never use Unicode subscripts in output.
CSV rules: the output must include a header row naming every column.
""";

with entry:__main__ {
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
    assert res.gate_issues == [];
    assert res.ok, res.compile_errors;
    assert "def run(" in res.module_src;
    assert "GEN-RAW" in res.ir_text;
    print("SCENARIO lift e2e OK");
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
    kn_good = KnowledgeView(
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
    kn_bad = KnowledgeView(tools=list(kn_good.tools), knowledge=[]);   # r5 dropped + csv_rules read has no lane

    # call order: extract, 3 critics, spine, [io cx knBAD hil], REPAIR PASS [io cx knGOOD hil]
    pin_all_lift_llms(MockLLM(model_name="mockllm", config={"outputs": [
        spec, [], [], [],
        wf,
        io, cx, kn_bad, HILView(),
        io, cx, kn_good, HILView()
    ]}));

    res = lift(SKILL, "csv-toy", parallel=False);
    assert len([r for r in res.repairs if "view repair" in r]) == 1;
    assert res.assemble_issues == [];
    assert res.ok, res.compile_errors;
    print("SCENARIO lift view-repair OK");
}
