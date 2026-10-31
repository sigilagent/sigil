"""AI compiler — the typed AG-IR views.

The AG-IR is one graph read four ways (flowchart / CFG / dataflow / knowledge).
Each LIFT stage emits ONE view as a typed object; the assembler joins them on the
rule-id spine (`traces_to`). Every obj is walker-safe: all fields defaulted, no
`T | None`.
"""

import from src.sigil_ais { canonical_opcode }

enum NodeType {
    SELECT, EXTRACT, MUTATE, GENERATE,
    DELEGATE,
    COMPUTE, OBSERVE, ACT,
    BRANCH, LOOP, PARALLEL, CALL,
    RETURN
}
sem NodeType = "The Agent Instruction Set (AIS) opcode. The opcode decides who executes it: SELECT/EXTRACT/MUTATE/GENERATE/DELEGATE run on the model; every other opcode runs as code.";
sem NodeType.SELECT = "Semantic: choose among a specified set of alternatives — the TIGHTEST semantic form. 'Classify the operation' is SELECT, not GENERATE.";
sem NodeType.EXTRACT = "Semantic: derive typed or structured information (a declared object) from semantic input.";
sem NodeType.MUTATE = "Semantic: modify an existing value according to instructions, touching only what must change.";
sem NodeType.GENERATE = "Semantic: produce new open-ended content — reserve for genuinely open-ended output.";
sem NodeType.DELEGATE = "Delegated: a bounded subtask whose internal orchestration is deliberately left to the runtime agent, with declared context, tools (autonomy_tools) and output contract.";
sem NodeType.COMPUTE = "Executable: invoke an available local computation — a pure function of its inputs, no guess.";
sem NodeType.OBSERVE = "Executable: obtain a value from an external source (read, grep, fetch, a check). Idempotent.";
sem NodeType.ACT = "Executable: cause an externally visible effect (write a file, emit the deliverable).";
sem NodeType.BRANCH = "Control: select an explicit successor using an available value or predicate (guards over carries).";
sem NodeType.LOOP = "Control: repeat an explicitly represented region, with a verdict and a cap.";
sem NodeType.PARALLEL = "Control: execute explicitly represented regions independently or concurrently.";
sem NodeType.CALL = "Control: invoke another named procedure.";
sem NodeType.RETURN = "Termination: the single exit; returns the produced carries as the report.";

# The AIS execution classes, as NodeType sets (paper Table 1).
glob SEMANTIC_TYPES: list[any] = [NodeType.SELECT, NodeType.EXTRACT, NodeType.MUTATE, NodeType.GENERATE];
glob MODEL_TYPES: list[any] = [NodeType.SELECT, NodeType.EXTRACT, NodeType.MUTATE, NodeType.GENERATE, NodeType.DELEGATE];

enum Owner { MODEL, CODE }
sem Owner = "Who executes the node. Derived from the opcode (MODEL for the semantic opcodes and DELEGATE, CODE otherwise) — never chosen independently.";

def node_type_of(raw: any) -> NodeType {
    # Any spelling of an opcode (paper or legacy) -> its NodeType; unknown
    # spellings read as GENERATE, the loosest semantic instruction.
    op = canonical_opcode(raw);
    for t in NodeType {
        if t.name == op { return t; }
    }
    return NodeType.GENERATE;
}

def unit_for(t: NodeType) -> Owner {
    return Owner.MODEL if t in MODEL_TYPES else Owner.CODE;
}

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
    has env_report: list[str] = [];    # G6_ENV findings (also in gate_issues unless advisory)
    has par_report: list[str] = [];    # G6_PAR opportunities + DLP candidates (advisory)
    # fix-forward contract (report.jac): a lift FAILS only when no runnable
    # module exists — everything else compiles, persists, and reports.
    #   failed    no runnable module (COMPILE rejected after the whole repair ladder)
    #   degraded  runnable, with residual warn/error findings riding the report
    #   fixed     runnable and clean, but only because fixes/repairs landed
    #   clean     runnable, nothing found, nothing needed
    has status: str = "failed";
    has findings: list[dict[str, any]] = [];     # {gate, severity, message} — residual, post-fix
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
