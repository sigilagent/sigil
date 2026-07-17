"""Tests — the WorkFlow spine. The validator is exercised directly (pure code);
the loop is driven by a scripted MockLLM: round one omits a MANDATORY rule and
the concurrency note, round two converges."""

import from jaclang.byllm.lib { MockLLM }

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

test "a well-formed spine validates clean" {
    assert validate_spine(_spec(), _good_view()) == [];
}

test "an unrealized MANDATORY rule is flagged (no-monolith precursor)" {
    v = _good_view();
    v.nodes = [n for n in v.nodes if n.id != "emit"];
    v.edges = [e for e in v.edges if (e.src != "emit") and (e.dst != "emit")];
    v.edges.append(AgirEdge(src="explore", dst="done", modality=Modality.MANDATORY, traces_to="r2"));
    issues = validate_spine(_spec(), v);
    assert len([i for i in issues if "'r3'" in i and "realized by no node" in i]) == 1;
}

test "a shredded INVOKE_UNIT rule is flagged (cognition preservation)" {
    v = _good_view();
    # split the adaptive explore step into two fixed halves — the anti-pattern
    v.nodes = [n for n in v.nodes if n.id != "explore"];
    v.nodes.append(AgirNode(id="explore_a", ntype=NodeType.CODE, owner=Owner.CODE, traces_to=["r2"]));
    v.nodes.append(AgirNode(id="explore_b", ntype=NodeType.CODE, owner=Owner.CODE, traces_to=["r2"]));
    v.edges = [
        AgirEdge(src="parse", dst="explore_a"), AgirEdge(src="explore_a", dst="explore_b"),
        AgirEdge(src="explore_b", dst="emit"), AgirEdge(src="emit", dst="done")
    ];
    issues = validate_spine(_spec(), v);
    assert len([i for i in issues if "shredded" in i]) == 1;
}

test "an INVOKE_UNIT lowered to a code node is flagged" {
    v = _good_view();
    for n in v.nodes {
        if n.id == "explore" { n.ntype = NodeType.CODE; n.owner = Owner.CODE; }
    }
    issues = validate_spine(_spec(), v);
    assert len([i for i in issues if "non-cognitive" in i]) == 1;
}

test "structural breakage is flagged: bad edge, two terminals, silent concurrency" {
    v = _good_view();
    v.edges.append(AgirEdge(src="emit", dst="nowhere"));
    v.nodes.append(AgirNode(id="done2", ntype=NodeType.TERMINAL));
    v.spawn_note = "";
    issues = validate_spine(_spec(), v);
    assert len([i for i in issues if "unknown node 'nowhere'" in i]) == 1;
    assert len([i for i in issues if "exactly one TERMINAL" in i]) == 1;
    assert len([i for i in issues if "spawn_note" in i]) == 1;
}

test "a FORBIDDEN rule with no constraints entry is flagged" {
    v = _good_view();
    v.constraints = [];
    issues = validate_spine(_spec(), v);
    assert len([i for i in issues if "'r4'" in i and "constraints" in i]) == 1;
}

# NOTE: the MockLLM convergence run lives in scenarios/workflow_loop.jac (run
# via `jac run` in CI) — under multi-module `jac test` the runtime resets the
# slot's __globals__ and the schema build dies (see ci.yml).
