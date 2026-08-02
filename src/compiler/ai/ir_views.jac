"""AI compiler — the typed AG-IR views.

The AG-IR is one graph read four ways (flowchart / CFG / dataflow / knowledge).
Each LIFT stage emits ONE view as a typed object; the assembler joins them on the
rule-id spine (`traces_to`). Every obj is walker-safe: all fields defaulted, no
`T | None`.
"""

enum NodeType {
    GEN_RAW, GEN_ENUM, GEN_FILL, GEN_EDIT,
    ROUTE, LOOP, SPAWN, CALL,
    SENSE, ACT, CODE, TERMINAL
}
sem NodeType = "The AG-IR action-type alphabet. Mind (GEN_*) always owner=MODEL; CODE always owner=CODE; Flow/Boundary either.";
sem NodeType.GEN_ENUM = "Choose from a fixed set — the TIGHTEST Mind form. 'Classify the operation' is GEN_ENUM, not GEN_RAW.";
sem NodeType.GEN_FILL = "Fill a typed object from context (schema-validated).";
sem NodeType.GEN_EDIT = "Mutate existing content touching only what must change.";
sem NodeType.GEN_RAW = "Free-form generation — reserve for genuinely open-ended output.";
sem NodeType.SENSE = "Pull world-state in (read, grep, fetch). Idempotent.";
sem NodeType.ACT = "Push an effect out (write a file, emit the deliverable).";
sem NodeType.CODE = "Pure function of inputs — no guess, runs for free.";
sem NodeType.TERMINAL = "The single exit node; serializes produced carries into the report.";

enum Owner { MODEL, CODE }
sem Owner = "Who fires the node: MODEL needs a guess; CODE is a function of its inputs (the Owner test).";

obj AssembleResult {
    has ir_text: str = "";
    has issues: list[str] = [];
}

obj LiftResult {
    has ok: bool = False;
    has ir_text: str = "";
    has module_src: str = "";
    has compile_errors: str = "";
    has spec_issues: list[str] = [];
    has spine_issues: list[str] = [];
    has assemble_issues: list[str] = [];
    has gate_issues: list[str] = [];
    has repairs: list[str] = [];
    has env_report: list[str] = [];    # G7-ENV findings (also in gate_issues unless advisory)
    has par_report: list[str] = [];    # G8-PAR opportunities + DLP candidates (advisory)
    # fix-forward contract (report.jac): a lift FAILS only when no runnable
    # module exists — everything else compiles, persists, and reports.
    #   failed    no runnable module (G4 rejected after the whole repair ladder)
    #   degraded  runnable, with residual warn/error findings riding the report
    #   fixed     runnable and clean, but only because fixes/repairs landed
    #   clean     runnable, nothing found, nothing needed
    has status: str = "failed";
    has findings: list[dict] = [];     # {gate, severity, message} — residual, post-fix
    has fixes: list[str] = [];         # mechanical autofix notes (model repairs ride `repairs`)
}

obj StructCov {
    has gated: list[str] = [];
    has slotted: list[str] = [];
    has monolithic: list[str] = [];
    has missing: list[str] = [];
    has issues: list[str] = [];
}
sem StructCov = "STRUCT-COV: per MANDATORY rule, HOW the compiled agent realizes it — gated (owner=code ability, guaranteed by construction), slotted (a dedicated model slot), monolithic (folded into another slot — model-dependent, same risk as prose), or missing. monolithic/missing name exactly where to strengthen the graph.";
