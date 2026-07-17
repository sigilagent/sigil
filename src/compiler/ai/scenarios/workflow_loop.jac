"""Scenario — the WorkFlow spine convergence loop, MockLLM-scripted.

Runs under `jac run` (CI step): under multi-module `jac test` the runtime
resets the slot's __globals__ and the schema build dies with NameError — the
same content as the former annex test, in the harness where slots work.
Exits nonzero on failure."""

import from jaclang.byllm.lib { MockLLM }
import from src.compiler.ai.lift_types { Modality, RuleKind, Cohesion }
import from src.compiler.ai.spec_loop { Rule, RuleSet }
import from src.compiler.ai.ir_views { NodeType, Owner }
import from src.compiler.ai.workflow {
    AgirNode, AgirEdge, WorkflowView, workflow_spine, pin_workflow_llm
}

glob SKILL: str = """# CSV Extractor
Parse the input file with the standard library.
Use the tools to explore the data until the schema is clear.
Always write the output as CSV with a header row.
Never use Unicode subscripts in output.
""";

def _spec() -> RuleSet {
    return RuleSet(skill_name="csv", rules=[
        Rule(id="r1", quote="Parse the input file with the standard library.",
             kind=RuleKind.STEP, modality=Modality.MANDATORY),
        Rule(id="r2", quote="Use the tools to explore the data until the schema is clear.",
             kind=RuleKind.STEP, modality=Modality.MANDATORY, cohesion=Cohesion.INVOKE_UNIT),
        Rule(id="r3", quote="Always write the output as CSV with a header row.",
             kind=RuleKind.IO, modality=Modality.MANDATORY),
        Rule(id="r4", quote="Never use Unicode subscripts in output.",
             kind=RuleKind.CONSTRAINT, modality=Modality.FORBIDDEN)
    ]);
}

def _good_view() -> WorkflowView {
    return WorkflowView(
        nodes=[
            AgirNode(id="parse", ntype=NodeType.SENSE, owner=Owner.CODE,
                     doc="Parse the input file.", reads=["task"], writes=["data"], traces_to=["r1"]),
            AgirNode(id="explore", ntype=NodeType.GEN_RAW, owner=Owner.MODEL,
                     doc="Explore the data until the schema is clear.",
                     reads=["data"], writes=["schema"],
                     autonomy_tools=["read_rows", "sample_column"], traces_to=["r2"]),
            AgirNode(id="emit", ntype=NodeType.ACT, owner=Owner.CODE, surface="artifact",
                     doc="Write the output as CSV with a header row.",
                     reads=["data", "schema"], writes=["artifact"], traces_to=["r3"]),
            AgirNode(id="done", ntype=NodeType.TERMINAL)
        ],
        edges=[
            AgirEdge(src="parse", dst="explore", modality=Modality.MANDATORY, traces_to="r1"),
            AgirEdge(src="explore", dst="emit", modality=Modality.MANDATORY, traces_to="r2"),
            AgirEdge(src="emit", dst="done", modality=Modality.MANDATORY, traces_to="r3")
        ],
        spawn_note="sequential: each step consumes the prior step's output",
        constraints=["r4: Never use Unicode subscripts in output."]
    );
}

with entry:__main__ {
    bad = _good_view();
    bad.nodes = [n for n in bad.nodes if n.id != "emit"];
    bad.edges = [e for e in bad.edges if (e.src != "emit") and (e.dst != "emit")];
    bad.edges.append(AgirEdge(src="explore", dst="done", modality=Modality.MANDATORY, traces_to="r2"));
    bad.spawn_note = "";

    pin_workflow_llm(MockLLM(model_name="mockllm", config={"outputs": [bad, _good_view()]}));
    res = workflow_spine(_spec(), SKILL);
    assert res.issues == [];
    assert res.rounds == 2;
    assert len(res.view.nodes) == 4;
    print("SCENARIO workflow_loop OK");
}
