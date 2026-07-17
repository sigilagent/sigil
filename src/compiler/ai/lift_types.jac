"""AI compiler (LIFT front-end) — shared enums + code-side verdicts.

The typed vocabulary of the SKILL -> AG-IR front-end: the extracted rule spec
(the anchor every later stage is audited against) and the gate verdicts. Every
obj is graph/walker-safe per the lowering discipline: every field defaulted, no
`T | None` (sentinels instead).
"""

enum Modality { MANDATORY, DISCRETIONARY, FORBIDDEN }
sem Modality = "How binding a rule is, read from the skill's deontic vocabulary.";
sem Modality.MANDATORY = "The prose says must / always / 'follow its instructions'.";
sem Modality.DISCRETIONARY = "The prose says may / if needed / 'for advanced... see'.";
sem Modality.FORBIDDEN = "The prose says never / do not.";

enum RuleKind { STEP, CONSTRAINT, IO, KNOWLEDGE, HIL, GROUNDING }
sem RuleKind = "What kind of obligation the rule states.";
sem RuleKind.STEP = "A procedural move the agent performs (an imperative).";
sem RuleKind.CONSTRAINT = "A standing restriction on outputs or behavior (often FORBIDDEN).";
sem RuleKind.IO = "An input the agent reads or a deliverable it must produce.";
sem RuleKind.KNOWLEDGE = "Reference material / a pattern the skill supplies (a code snippet, a template, a 'see X.md' pointer).";
sem RuleKind.HIL = "A human-in-the-loop gate: confirm / approve / ask before proceeding.";
sem RuleKind.GROUNDING = "A demand to consult a LIVE source at run time (web fetch, live API, running server) — not paraphrasable from memory.";

enum Cohesion { ATOMIC, INVOKE_UNIT }
sem Cohesion = "Whether the rule's span may be decomposed further during lowering.";
sem Cohesion.ATOMIC = "A single fixed move; safe to lower as its own node.";
sem Cohesion.INVOKE_UNIT = "An adaptive tool-using activity ('explore...', 'iterate until...', 'use the tools to...') that must stay ONE cognitive unit with a tool-belt — shredding it into fixed calls destroys the observe-and-adapt loop.";

obj CompileVerdict {
    has ok: bool = False;
    has module_src: str = "";
    has errors: str = "";
}

