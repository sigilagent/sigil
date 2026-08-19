"""Scenario — the adjudicator tier, MockLLM-scripted. See workflow_loop.jac for
why this runs under `jac run` instead of `jac test`. Exits nonzero on failure.

The point of the scenario is the STACK, which no unit test shows end to end:

  1. apply_structural_modality settles the obligations under '## Required steps'
     deterministically -- and, by the same structural read, the numbered step
     under '## Procedure', which states no force of its own. They never become
     clarify items, so the model is never asked about them and cannot change them.
  2. The adjudicator sees ONLY the residue under '## Notes', where the document
     states no force.
  3. Whatever it answers must cite the document, or it is refused.

Two runs over that residue: once with cited evidence (binds), once with
confident, plausible, ungrounded answers (all refused). The second run is the
load-bearing one -- it is the exact failure mode the grounding check exists for,
and nothing downstream could catch it, because the faith report audits the
module against the spec and never the spec against the world.

A third run covers the OTHER way an answer can be wrong: not ungrounded, but
out of bounds. It answers a procedural step -- with evidence that is perfectly
verbatim -- and is refused for the only reason that matters here, that structure
already settled it and it was never asked. That is the whole point of settling
at tier 1: a well-evidenced answer is still not admissible on a question the
compiler did not put to the model.
"""

import from jaclang.byllm.lib { MockLLM }
import from src.compiler.ai.lift_types { Modality, RuleKind }
import from src.compiler.ai.spec_loop {
    Rule, RuleSet, SpecResult, Adjudication, adjudicate_spec, flag_ambiguous,
    apply_structural_modality, pin_adjudge_llm, set_spec_progress, section_context
}

glob SKILL: str = """# Release Guide

## Required steps
Run the validator before shipping.
Update the changelog.

## Procedure
1. Tag the release commit.

## Notes
Delete the upstream remote.
Notify the release channel.
""";

glob _seen: list = [];

def _capture(ev: dict) -> None { _seen.append(str(ev.get("phase"))); }

def _fresh() -> SpecResult {
    # what the extractor would hand over: five unmarked spans, all defaulted to
    # MANDATORY, three of which their section actually governs
    rs = RuleSet(skill_name="release-guide", rules=[
        Rule(id="r1", quote="Run the validator before shipping.",
             kind=RuleKind.STEP, modality=Modality.MANDATORY),
        Rule(id="r2", quote="Update the changelog.",
             kind=RuleKind.STEP, modality=Modality.MANDATORY),
        Rule(id="r6", quote="Delete the upstream remote.",
             kind=RuleKind.STEP, modality=Modality.MANDATORY),
        Rule(id="r7", quote="Notify the release channel.",
             kind=RuleKind.STEP, modality=Modality.MANDATORY),
        Rule(id="r8", quote="Tag the release commit.",
             kind=RuleKind.STEP, modality=Modality.MANDATORY)
    ]);
    sr = SpecResult(spec=rs);
    sr.settled = apply_structural_modality(SKILL, rs);   # tier 1, deterministic
    sr.clarify = flag_ambiguous(SKILL, rs, sr.settled);  # only the residue is flagged
    return sr;
}

def _mod(sr: SpecResult, rid: str) -> str {
    for r in sr.spec.rules { if r.id == rid { return r.modality.name; } }
    return "?";
}

with entry:__main__ {
    pin_adjudge_llm(MockLLM(model_name="mockllm", config={"outputs": [
        # run 1 — grounded: cites the heading, and OMITS the one it cannot settle
        [Adjudication(rule_id="r6", answer="maybe", evidence="## Notes",
                      rationale="the section is commentary, not a required step")],
        # run 2 — ungrounded: every span is world knowledge, not document text
        [Adjudication(rule_id="r6", answer="do",
                      evidence="Removing stale remotes is standard git hygiene.",
                      rationale="best practice"),
         Adjudication(rule_id="r7", answer="do",
                      evidence="Release announcements are expected of maintainers.",
                      rationale="best practice")],
        # run 3 -- grounded, and still inadmissible: it answers a step the
        # document already settled, so it was never in the packet to begin with
        [Adjudication(rule_id="r8", answer="maybe", evidence="## Procedure",
                      rationale="reads as a suggested workflow")]
    ]}));

    set_spec_progress(_capture);

    # ---- tier 1 kept the governed spans away from the model entirely ---------
    one = _fresh();
    assert one.settled.get("r1");                       # '## Required steps' stated it
    assert one.settled.get("r2");
    assert one.settled.get("r8");                       # '## Procedure' claimed the step
    assert "Procedure" in str(one.settled.get("r8"));   # and the binding says so
    ids = sorted([c.rule_id for c in one.clarify]);
    assert ids == ["r6", "r7"];                         # ONLY the residue is asked about
    assert _mod(one, "r1") == "MANDATORY";
    assert _mod(one, "r2") == "MANDATORY";
    assert _mod(one, "r8") == "MANDATORY";               # the list IS the procedure

    # the evidence packet is assembled by CODE before the model is consulted
    ctx = section_context(SKILL, "Delete the upstream remote.");
    assert "Notes" in ctx;
    assert "Delete the upstream remote." not in ctx;    # never its own evidence

    # ---- run 1: a grounded answer binds; an omission falls to the default ----
    w1 = adjudicate_spec(SKILL, one);
    assert _mod(one, "r6") == "DISCRETIONARY";          # answered a Maybe, on a cited heading
    assert _mod(one, "r7") == "DISCRETIONARY";          # omitted -> standing default
    assert _mod(one, "r1") == "MANDATORY";              # tier 1's work is untouched
    assert _mod(one, "r8") == "MANDATORY";
    assert any([("ANSWERED by the adjudicator" in w) for w in w1]);
    assert any([("skill evidence" in w) for w in w1]);
    assert any([("ASSUMED to be MAYBE" in w) for w in w1]);
    assert any([("r7" in w) for w in w1]);              # the unanswered one is still reported

    # ---- run 2: confident, plausible, ungrounded answers are refused --------
    two = _fresh();
    w2 = adjudicate_spec(SKILL, two);
    for rid in ["r6", "r7"] {
        # NEITHER hardened. Two fluent answers, and the compile ends exactly as
        # conservative as if the adjudicator had never run.
        assert _mod(two, rid) == "DISCRETIONARY";
    }
    assert any([("rejected by the grounding check" in w) for w in w2]);
    assert any([("not verbatim" in w) for w in w2]);
    assert any([("ANSWERED by the adjudicator" in w) for w in w2]) == False;

    # ---- run 3: a grounded answer on a question that was never asked --------
    # Before the procedural read moved into infer_modality, this exact answer
    # LANDED: the step was flagged, '## Procedure' is verbatim and sits outside
    # the obligation's own sentence, so it cleared every grounding check and the
    # step was demoted to DISCRETIONARY -- while an identical step the model
    # happened not to answer stayed MANDATORY. Structure decides this now, and
    # decides it before the packet is built.
    three = _fresh();
    assert "r8" not in [c.rule_id for c in three.clarify];
    w3 = adjudicate_spec(SKILL, three);
    assert _mod(three, "r8") == "MANDATORY";             # the demotion never lands
    assert any([("adjudicated but never flagged" in w) for w in w3]);
    assert any([("ANSWERED by the adjudicator" in w) for w in w3]) == False;
    assert _mod(three, "r6") == "DISCRETIONARY";         # the real residue still defaults
    assert _mod(three, "r7") == "DISCRETIONARY";

    set_spec_progress(None);
    assert _seen.count("adjudicate") == 3;

    print("SCENARIO adjudicate OK");
}
