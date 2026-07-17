"""Tests — the end-to-end LIFT. One scripted MockLLM drives every model stage
(spec loop -> spine -> the four flows); assemble + the G4 oracle then run LIVE:
the pipeline's output is a real AG-IR that must transpile + jac-check clean."""

import from jaclang.byllm.lib { MockLLM }
import from .lift_types { Modality, RuleKind }
import from .spec_loop { Rule, RuleSet }
import from .ir_views { NodeType, Owner }
import from .workflow { AgirNode, AgirEdge, WorkflowView }
import from .flows { Carry, IOView, Residency, ContextView, ToolDef, KnowledgeItem, KnowledgeView, HILView }

glob SKILL: str = """# CSV Toy
Parse the input file with the standard library.
Summarize the data in one sentence.
Always write the output as CSV with a header row.
Never use Unicode subscripts in output.
CSV rules: the output must include a header row naming every column.
""";

# NOTE: the end-to-end and view-repair runs live in scenarios/lift_e2e.jac
# (run via `jac run` in CI) — the multi-module jac-test __globals__ bug again.
