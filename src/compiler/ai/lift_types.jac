"""AI compiler (LIFT front-end) — shared types.

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

obj Rule {
    has id: str = "";
    has quote: str = "";
    has kind: RuleKind = RuleKind.STEP;
    has modality: Modality = Modality.MANDATORY;
    has condition: str = "";
    has cohesion: Cohesion = Cohesion.ATOMIC;
}
sem Rule = "One atomic obligation extracted from the skill text.";
sem Rule.id = "Stable short id (r1, r2, ...). Keep ids stable across revision rounds.";
sem Rule.quote = "The VERBATIM span from the skill text this rule comes from, copied character-for-character (whitespace may be collapsed). NEVER paraphrase, summarize, or invent — a quote that does not appear in the skill gets the rule mechanically dropped.";
sem Rule.condition = "If the span is conditional or exemplary ('when uncertain...', 'if the task...', 'e.g. ...'), the condition VERBATIM. Empty only when the span is genuinely unconditional. Hardening a conditional into an unconditional mandate is a faithfulness violation.";

obj RuleSet {
    has skill_name: str = "";
    has rules: list[Rule] = [];
    has sub_resources: list[str] = [];
}
sem RuleSet = "The complete extracted spec of a skill: every obligation the prose states — nothing added, nothing dropped, nothing re-modalized.";
sem RuleSet.sub_resources = "Sibling bundle files the skill itself delegates to (FORMS.md, REFERENCE.md, ...).";

obj ExtractVerdict {
    has sound: bool = False;
    has complete: bool = False;
    has drift: bool = True;
    has ungrounded: list[str] = [];
    has uncovered: list[str] = [];
    has drift_notes: list[str] = [];
    has changed: bool = True;
    has rounds: int = 0;
}

obj CompileVerdict {
    has ok: bool = False;
    has module_src: str = "";
    has errors: str = "";
}

obj SpecResult {
    has spec: RuleSet = RuleSet();
    has verdict: ExtractVerdict = ExtractVerdict();
}
