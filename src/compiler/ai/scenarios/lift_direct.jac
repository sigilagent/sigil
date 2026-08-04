"""Scenario — the DIRECT lift() front-end (the new default): the spec loop runs,
then ONE authoring call returns the whole AG-IR, then the shared fix-forward tail
lowers + gates it LIVE. MockLLM-scripted (extract_spec's calls, then the authored
IR); assemble/G4 are real. Exits nonzero on failure."""

import from jaclang.byllm.lib { MockLLM }
import from src.compiler.ai.lift_types { Modality, RuleKind }
import from src.compiler.ai.spec_loop { Rule, RuleSet }
import from src.compiler.ai.lift { lift, pin_all_lift_llms, set_lift_progress }

glob SKILL: str = """# CSV Toy
Parse the input file with the standard library.
Summarize the data in one sentence.
Always write the output as CSV with a header row.
Never use Unicode subscripts in output.
""";

# The AG-IR the (mocked) authoring pass returns — traces every mandatory STEP/IO
# rule (r1/r2/r3), binds code tools, types its carries.
glob AUTHORED: str = """---
name: csv-toy
description: Parse a file, summarize it, and emit CSV with a header row.
---
agir_version: 0.1
standalone: true
shape: pipeline
types: {}
tools:
  parse_input:
    sig: "(task) -> str"
    surface: SENSE
    serves: [parse]
    body: |
      def parse_input(task):
          return "col_a,col_b\\n1,2\\n3,4"
  write_csv:
    sig: "(data, summary) -> str"
    surface: ACT·artifact
    serves: [emit]
    body: |
      def write_csv(data, summary):
          with open("out.csv", "w") as f:
              f.write(str(data))
          return "out.csv"
walker:
  name: CsvToy
  carries:
    task:     { type: str, role: input }
    data:     { type: str, produced_by: parse }
    summary:  { type: str, produced_by: summarize }
    artifact: { type: str, produced_by: emit }
nodes:
  - id: parse
    type: SENSE
    owner: code
    op: parse_input
    tool: parse_input
    reads: [task]
    writes: [data]
    traces_to: [r1]
  - id: summarize
    type: GEN-RAW
    owner: model
    reads: [data]
    writes: [summary]
    doc: "Summarize the data in one sentence. NEVER use Unicode subscripts."
    traces_to: [r2]
  - id: emit
    type: ACT
    owner: code
    op: write_csv
    tool: write_csv
    reads: [data, summary]
    writes: [artifact]
    traces_to: [r3]
  - id: done
    type: TERMINAL
edges:
  - {from: parse, to: summarize, modality: mandatory}
  - {from: summarize, to: emit, modality: mandatory}
  - {from: emit, to: done, modality: mandatory}
""";

glob _events: list = [];
def _collect(ev: dict) -> None { _events.append(ev); }

with entry:__main__ {
    set_lift_progress(_collect);
    spec = RuleSet(skill_name="csv-toy", rules=[
        Rule(id="r1", quote="Parse the input file with the standard library.", kind=RuleKind.STEP, modality=Modality.MANDATORY),
        Rule(id="r2", quote="Summarize the data in one sentence.", kind=RuleKind.STEP, modality=Modality.MANDATORY),
        Rule(id="r3", quote="Always write the output as CSV with a header row.", kind=RuleKind.IO, modality=Modality.MANDATORY),
        Rule(id="r4", quote="Never use Unicode subscripts in output.", kind=RuleKind.CONSTRAINT, modality=Modality.FORBIDDEN)
    ]);

    # extract_spec consumes [spec, critic, critic, critic]; then the ONE authoring
    # call consumes AUTHORED. No spine/flows/assemble calls on the direct path.
    pin_all_lift_llms(MockLLM(model_name="mockllm", config={"outputs": [
        spec, [], [], [],
        AUTHORED
    ]}));

    res = lift(SKILL, "csv-toy", parallel=False);

    assert res.ir_text, "direct lift produced no IR";
    assert "def run(" in res.module_src, "direct lift did not lower to a runnable module";
    assert "CsvToy" in res.module_src, res.module_src[:200];
    assert res.status in ["clean", "fixed", "degraded"], "unexpected status: " + res.status;
    assert res.repairs and str(res.repairs[0]).startswith("front-end: direct"), str(res.repairs[:2]);

    _done = [str(e["stage"]) for e in _events if str(e.get("state")) == "done"];
    assert "author" in _done, _done;
    assert "spine" not in _done, "direct path must not run the staged spine: " + str(_done);
    assert "flows" not in _done, "direct path must not run flows: " + str(_done);

    print("SCENARIO lift direct OK (status=" + res.status + ", " + str(len(res.ir_text.splitlines())) + " IR lines)");
}
