"""Effect gate (G6_EFFECT) — check each tool's `surface` against the code it binds.

The compile-time model writes every tool's surface (OBSERVE / ACT), and lowering
trusts it: an ACT tool's path parameters resolve write-side, an OBSERVE tool is
dispatched as a sense tool, and the AG-IR spec says an OBSERVE must not change
external state. The other gates check coverage, types, references and that every
executable step is bound; none compares the label with what the bound code does.
For `command: python scripts/x.py ...` the AG-IR holds only the command line, so
this gate opens the skill folder.

Two readers, cheapest first. effect_scan.jac parses the code and runs nothing; a tool
it finds clean is done. With a compile model pinned (pin_effect_llm, through
pin_raise2_llms), each non-ACT tool the scan flags or cannot follow is read once more
by the model, from the code alone (tool_source: no label, no doc). The model clears
scan false alarms and settles what the scan cannot follow.

"Writes" follows ais-spec: any change to state outside the process (§4.3.1),
temporary files and intermediates included (§4.3.2, surface workspace), and the writes
a runtime makes on its own (npm's debug log, a bundled module's __pycache__).

The gate reads a tool the way lowering runs it: a code-less tool named after a builtin
is checked against the builtin's body, and an instruction is bound to a tool by
lowering's own _node_tool.

A non-ACT tool whose code writes goes to the compile model first (repair_effects, a
slot for this one error class), for a bounded number of attempts. A candidate is
adopted only if it fixes a finding (a rewrite still has code, which the scan finds
clean), the scan finds no other writing tool below ACT and no new instruction calling
a writing tool its opcode may not, it still lowers (unless the input did not), and,
when a spec is given, it keeps the faithfulness proof. What the model does not fix is
relabeled ACT mechanically. The model may also change an instruction's opcode or the procedure;
the mechanical fallback changes only the tool's surface, because OBSERVE and ACT
instructions lower differently, and a warning names an instruction left OBSERVE.
A repair never changes an instruction's own `surface`: lowering reports what an ACT
instruction with an artifact surface writes as a deliverable, so a new surface can push
the skill's answer out of the terminal report. If the rung's change still alters which
carries that report shows (an opcode change can), a warning says which.

What nobody can settle becomes a repair-ladder line, not a warning: a strict compile
fails on any warning, and a reader's limits are not a skill defect.

Off with SIGIL_GATE_G6_EFFECT=off, or G6_EFFECT in SIGIL_GATES_OFF.
"""

import re;
import from jaclang.byllm.lib { Model }
import from src.compiler.mechanical.compiler { _load_ir, transpile_ir, _toolfn_prefix, _node_tool }
import from src.compiler.mechanical.toolib { builtin }
import from src.sigil_agir_yaml { dump_agir }
import from .report { gate_enabled }
import from .faith { faithfulness_report, gap_score }
import from .effect_scan { scan_tool, tool_source, source_complete }
import from .gates { compile_gate }

glob EFFECT_GATE: str = "G6_EFFECT";
# Bounds on the model check per compile: tools asked, and code characters per tool.
glob _MODEL_MAX_TOOLS: int = 12;
glob _MODEL_MAX_CHARS: int = 150000;

# The opcodes whose lowering calls the node's bound tool (compiler.jac, _node_tool's
# callers); a CALL calls its `procedure`.
glob _TOOL_OPCODES: list[str] = ["OBSERVE", "ACT", "COMPUTE", "BRANCH", "LOOP"];

glob effect_llm: any = Model(model_name="gpt-4o-mini");
glob _EFFECT_LLM_PINNED: bool = False;

def pin_effect_llm(m: any) -> None {
    # None unpins: the gate goes back to the scan alone.
    effect_llm = m;
    _EFFECT_LLM_PINNED = m is not None;
}

sem judge_effects = """You check one tool of a compiled agent skill. Read its code: the tool body or
command, and the bundled scripts it names. Decide whether running the tool, as
written, can change any state OUTSIDE its own process. That counts: creating,
writing, appending, deleting, renaming or changing permissions of a file or
directory, temporary ones included (tempfile, mkdtemp, NamedTemporaryFile, /tmp),
whether or not the code removes them afterwards; sending data over the network (a
request that only fetches does not count); writing a database; installing
packages; starting a process that does any of these. Writes a runtime makes on its
own count too: running npm or npx writes a debug log under ~/.npm/_logs, and
importing a bundled Python module writes its __pycache__ bytecode. It does not
count: in-memory buffers (BytesIO, StringIO); printing to stdout or stderr. Judge
only what the tool runs: a bundled script it only names, for example in a command
string it builds and returns, does not run. Judge the arguments the tool actually
passes: an option it never passes does not happen.
Reply with ONE line only: `yes: <the code that writes>`, `no: <why not>`, or
`unclear: <what you cannot see>`.""";
sem judge_effects.code = "The tool's code and the bundled scripts it runs. The tool's label and description are left out on purpose.";
def judge_effects(code: str) -> str by effect_llm();

sem repair_effects = """The AG-IR YAML labels a tool below what its bound code does: the findings
name each tool and the code that changes state outside the process. Return the COMPLETE
corrected AG-IR YAML (frontmatter included) fixing ONLY those findings: label the
tool ACT, and an instruction that calls it ACT where that step acts, or change the
procedure so that no OBSERVE step writes. Do not add, drop, or re-modalize anything
else. Output raw YAML only: no prose, no explanation, no markdown fences.""";
sem repair_effects.ir_text = "The full AG-IR YAML.";
sem repair_effects.findings = "The effect-gate findings to fix, and nothing else.";
def repair_effects(ir_text: str, findings: str) -> str by effect_llm();

obj EffectFinding {
    has kind: str = "";              # writes | unknown | opcode | cleared
    has tool: str = "";
    has surface: str = "";
    has nodes: list[str] = [];       # instructions bound to the tool
    has opcodes: list[str] = [];     # their `type`, same order
    has evidence: list[str] = [];    # what the code writes, or what the scan could not follow
    has source: str = "scan";        # scan | scan+model | model
    has model: str = "";             # the model's one-line answer, when it was asked
}

def effect_findings(ir_text: str, skill_dir: str = "") -> list[EffectFinding] {
    ir = _load_ir(ir_text);
    tools = ir.get("tools") if isinstance(ir, dict) else None;
    if not isinstance(tools, dict) { return []; }
    out: list[EffectFinding] = [];
    for (name, raw) in tools.items() {
        tool = _as_lowered(str(name), raw);
        s = scan_tool(tool, skill_dir);
        if not s["code"] { continue; }
        surface = str(tool.get("surface") or "");
        calls = _callers(ir, str(name));
        f = EffectFinding(tool=str(name), surface=surface, nodes=[str(c.get("id")) for c in calls],
                          opcodes=[str(c.get("type") or "") for c in calls]);
        if s["writes"] and not surface.startswith("ACT") {
            f.kind = "writes"; f.evidence = list(s["writes"]);
        } elif s["writes"] and len(_bad_callers(surface, f.opcodes)) > 0 {
            # The tool is honest; an instruction calling it is not. Report only (see module doc).
            f.kind = "opcode"; f.evidence = list(s["writes"]);
        } elif s["unknown"] and not surface.startswith("ACT") {
            f.kind = "unknown"; f.evidence = list(s["unknown"])[:3];
        } else {
            continue;
        }
        out.append(f);
    }
    return out;
}

def _bad_callers(surface: str, opcodes: list[str]) -> list[str] {
    # Opcodes that may not call a tool that writes. An OBSERVE never may (ais-spec §4.3.1).
    # A COMPUTE may call an ACT·artifact tool: §4.3.3 says it is then a write and binds
    # its path write-side. A COMPUTE calling a plain ACT tool is not pure.
    artifact = surface.startswith("ACT") and ("artifact" in surface);
    return [o for o in opcodes if o == "OBSERVE" or (o == "COMPUTE" and not artifact)];
}

def _as_lowered(name: str, tool: any) -> any {
    # The tool as lowering runs it. A tool named after a builtin, with no body or command of
    # its own, gets the builtin's body, and the builtin's surface when it has none
    # (compiler.jac, _normalize_builtins): `write_file` labeled OBSERVE writes all the same.
    if not isinstance(tool, dict) { return tool; }
    if str(tool.get("body") or "").strip() or str(tool.get("command") or "").strip() { return tool; }
    bi = builtin(name);
    if bi is None { return tool; }
    t = dict(tool);
    t["body"] = str(bi["body"]);
    if not str(t.get("surface") or "").strip() { t["surface"] = str(bi["surface"]); }
    return t;
}

def _callers(ir: dict[str, any], name: str) -> list[any] {
    # Instructions lowering binds to the tool, resolved by lowering's own _node_tool: a
    # node's `tool` (the first, when a list), else a tool whose `serves` lists it, else a
    # tool named like the node; a CALL by its `procedure`. `op` binds nothing.
    out: list[any] = [];
    for c in list(ir.get("nodes") or []) {
        if not isinstance(c, dict) { continue; }
        bound: any = [];
        try {
            if str(c.get("type") or "") == "CALL" {
                proc = str(c.get("procedure") or "").strip();
                bound = _node_tool(ir, proc, {"tool": proc}) if proc else [];
            } elif str(c.get("type") or "") in _TOOL_OPCODES {
                bound = _node_tool(ir, c.get("id"), c);
            }
        } except Exception {
            bound = [];   # a malformed tool entry: lowering fails on it too
        }
        if bound and str(bound[0]) == name { out.append(c); }
    }
    return out;
}

def model_verdict(answer: str) -> list[str] {
    # -> [yes | no | unclear, reason]. Anything that does not start with one of the
    # three words is "unclear", and an unclear answer never changes a verdict.
    text: str = str(answer or "").strip().strip("`").strip();
    first: str = text.splitlines()[0].strip() if text else "";
    word: str = re.split(r"[^a-z]", first.lower(), maxsplit=1)[0] if first else "";
    if word in ["yes", "no", "unclear"] {
        return [word, first[len(word):].lstrip(" :-").strip()[:240]];
    }
    return ["unclear", first[:240]];
}

def confirm_with_model(fs: list[EffectFinding], ir_text: str, skill_dir: str, lines: list[str], asked: int = 0) -> int {
    # The second reader, for what the scan flagged or could not follow; updates fs in place.
    # `asked`: tools already read in this compile, which share the one budget.
    # -> tools read in this compile, these included
    ir = _load_ir(ir_text);
    tools = (ir.get("tools") or {}) if isinstance(ir, dict) else {};
    for f in fs {
        if f.kind not in ["writes", "unknown"] { continue; }
        if asked >= _MODEL_MAX_TOOLS {
            lines.append(EFFECT_GATE + ": model check skipped for '" + f.tool + "' (limit of "
                         + str(_MODEL_MAX_TOOLS) + " tools per compile)");
            continue;
        }
        code: str = tool_source(_as_lowered(f.tool, tools.get(f.tool)), skill_dir);
        if not code { continue; }
        if len(code) > _MODEL_MAX_CHARS {
            lines.append(EFFECT_GATE + ": model check skipped for '" + f.tool + "' (" + str(len(code))
                         + " characters of code; the limit is " + str(_MODEL_MAX_CHARS) + ")");
            continue;
        }
        asked += 1;
        answer: str = "";
        try {
            answer = str(judge_effects(code));
        } except Exception as e {
            lines.append(EFFECT_GATE + ": model check failed for '" + f.tool + "' (" + str(e)[:120] + ")");
            continue;
        }
        v = model_verdict(answer);
        f.model = v[0] + ": " + v[1];
        was: str = f.kind;
        if v[0] == "yes" {
            if was == "unknown" { f.evidence = ["model: " + v[1]]; }
            f.kind = "writes";
            f.source = "scan+model" if was == "writes" else "model";
        } elif v[0] == "no" and not source_complete(code) {
            # a write may sit in what the model was not shown
            lines.append(EFFECT_GATE + ": tool '" + f.tool + "': the model found no external write, but a script was "
                         + "truncated or could not be read, so the scan's verdict stands: " + v[1]);
        } elif v[0] == "no" {
            f.kind = "cleared";
            seen: str = ("the scan reported " + "; ".join(f.evidence)) if was == "writes" else ("the scan could not follow: " + "; ".join(f.evidence));
            lines.append(EFFECT_GATE + ": tool '" + f.tool + "' kept as " + (f.surface or "(none)") + "; " + seen
                         + "; the model read the code and found no external write: " + v[1]);
        }
    }
    return asked;
}

def relabel_act(ir_text: str, tool_names: list[str]) -> str {
    # Set `surface: ACT` on the named tools; "" when nothing changed.
    ir = _load_ir(ir_text);
    if not isinstance(ir, dict) { return ""; }
    tools = ir.get("tools") or {};
    changed = False;
    for name in tool_names {
        spec = tools.get(name) if isinstance(tools, dict) else None;
        if isinstance(spec, dict) and (not str(spec.get("surface") or "").startswith("ACT")) {
            spec["surface"] = "ACT";
            changed = True;
        }
    }
    return str(dump_agir(ir)) if changed else "";
}

def _lower(ir_text: str, name: str) -> str {
    # the lowered module, or "" when the IR does not lower
    osp = "";
    try {
        osp = str(transpile_ir(ir_text, name));
    } except Exception as e {
        return "";
    }
    return osp if (("def run(" in osp) and ("can n_" in osp)) else "";
}

def _lowers(ir_text: str, name: str) -> bool {
    return bool(_lower(ir_text, name));
}

def _keep_instruction_surfaces(cand_text: str, cur_text: str) -> str {
    # A repair may relabel the flagged tools, change their callers' opcodes, or rewrite
    # their code. It may not change an instruction's own `surface`: lowering lists what an
    # ACT instruction with an artifact surface writes as a deliverable, and the final
    # report shows only a few, so a surface a repair added to a checker's caller pushed
    # the skill's own answer out of that report (a pufferlib compile: its checkpoint
    # check). Each instruction keeps the surface it had; an instruction the repair added
    # keeps what the repair wrote. A reply that is not an AG-IR is returned unchanged for
    # _judge_repair to refuse.
    cand: any = None;
    try { cand = _load_ir(cand_text); } except Exception { return cand_text; }
    cur = _load_ir(cur_text);
    if not (isinstance(cand, dict) and isinstance(cur, dict)) { return cand_text; }
    was: dict[str, any] = {};
    for n in list(cur.get("nodes") or []) {
        if isinstance(n, dict) { was[str(n.get("id"))] = n.get("surface"); }
    }
    changed = False;
    for n in list(cand.get("nodes") or []) {
        if not isinstance(n, dict) { continue; }
        nid = str(n.get("id"));
        if (nid not in was) or (n.get("surface") == was[nid]) { continue; }
        changed = True;
        if was[nid] is None { n.pop("surface", None); }
        else { n["surface"] = was[nid]; }
    }
    return str(dump_agir(cand)) if changed else cand_text;
}

def _report_fields(module: str) -> any {
    # the carries the terminal report shows (the line _terminal_report emits, compiler.jac), in
    # order; [] for a bare "<name> done"; None when there is no such line: the IR did not lower,
    # or it has no RETURN instruction
    for l in module.splitlines() {
        if "self.report = f" in l { return re.findall(r"\b([A-Za-z_][A-Za-z0-9_]*)=\{", l); }
    }
    return None;
}

def _report_change(was_text: str, now_text: str, name: str) -> str {
    # A warning when the rung's change alters which carries the terminal report shows, or ""
    # (also when either side has no report line, and when only their order changed). A relabel
    # moves tools between the dispatch tables, which the report does not read; an opcode change
    # can make a carry a deliverable, and the report shows only a few.
    was = _report_fields(_lower(was_text, name));
    now = _report_fields(_lower(now_text, name));
    if (was is None) or (now is None) or (set(was) == set(now)) { return ""; }
    gone = [f for f in was if f not in now];
    came = [f for f in now if f not in was];
    return (EFFECT_GATE + ": the repair changes which carries the terminal report shows: "
            + (", ".join(gone) or "(no carry)") + " -> " + (", ".join(came) or "(no carry)")
            + ". Check that the skill's answer is still reported.");
}

def _calls(module: str, tool: str) -> list[str] {
    # every call of the tool's lowered function, as source text: `_fetch_visit(None)`
    fn = _toolfn_prefix(tool);
    out: list[str] = [];
    for m in re.finditer(re.escape(fn) + r"\(", module) {
        s = m.start();
        if s > 0 and (re.match(r"[A-Za-z0-9_]", module[s - 1]) or module[max(0, s - 4):s] == "def ") { continue; }
        depth = 0;
        i = m.end() - 1;
        while i < len(module) {
            if module[i] == "(" { depth += 1; }
            elif module[i] == ")" {
                depth -= 1;
                if depth == 0 { break; }
            }
            i += 1;
        }
        out.append(re.sub(r"\s+", " ", module[s:i + 1]));
    }
    return out;
}

def effect_rung(ir_text: str, skill_dir: str, name: str, spec: any = None, attempts: int = 2, asked: int = 0) -> dict[str, any] {
    # `spec`: the compile's RuleSet; when given, no change may cost the faithfulness
    # proof. `attempts`: repair attempts by the compile model (raise2 passes max_repair).
    # `asked`: tools the model reader already read in this compile (effect_recheck).
    # -> {"ir_text": the IR, repaired or relabeled where that was adopted,
    #     "notes": repair-ladder lines for what changed,
    #     "report": repair-ladder lines for what was not settled or not adopted (never blocking),
    #     "warnings": skill-quality warnings, for the IR returned,
    #     "call_changes": the warnings that say a relabel changed how a tool is called,
    #     "report_changes": the warning that says the rung's change alters the terminal report,
    #     "findings": [gate, message] for each tool labeled below what its code does,
    #     "checked": every EffectFinding,
    #     "asked": tools the model reader has read in this compile, this rung included}
    out: dict[str, any] = {"ir_text": ir_text, "notes": [], "report": [], "warnings": [], "call_changes": [],
                           "report_changes": [], "findings": [], "checked": [], "asked": asked};
    if not gate_enabled(EFFECT_GATE) { return out; }
    fs: list[EffectFinding] = [];
    try {
        fs = effect_findings(ir_text, skill_dir);
    } except Exception as e {
        out["report"].append(EFFECT_GATE + ": the scan failed, labels not checked (" + str(e)[:160] + ")");
        return out;
    }
    if _EFFECT_LLM_PINNED { out["asked"] = confirm_with_model(fs, ir_text, skill_dir, out["report"], asked); }
    out["checked"] = fs;
    for f in fs {
        if f.kind == "unknown" {
            out["report"].append(EFFECT_GATE + ": tool '" + f.tool + "' (" + (f.surface or "no surface")
                                 + ") not checked; the scan could not follow: " + "; ".join(f.evidence)
                                 + ((" (model: " + f.model + ")") if f.model else ""));
        }
    }
    writes = [f for f in fs if f.kind == "writes"];
    cur = ir_text;
    rewritten: list[str] = [];
    if writes {
        r = _repair_writes(writes, ir_text, skill_dir, name, spec, attempts, out);
        cur = str(r[0]);
        rewritten = list(r[1]);
    }
    out["ir_text"] = cur;
    if cur != ir_text {
        w = _report_change(ir_text, cur, name);
        if w {
            out["warnings"].append(w);
            out["report_changes"].append(w);
        }
    }
    # Warnings hold for the IR the rung returns: an instruction a repair made ACT is not
    # warned about (a strict compile fails on any warning).
    for f in fs {
        if f.kind == "opcode" {
            for c in _observe_callers_in(cur, f.tool) {
                out["warnings"].append(EFFECT_GATE + ": instruction '" + c + " calls '" + f.tool
                                       + "', which changes state outside the process (" + "; ".join(f.evidence)
                                       + "). Make the instruction ACT, or bind a tool that does not write.");
            }
        } elif f.kind == "writes" and f.tool not in rewritten {
            for c in _observe_callers_in(cur, f.tool) {
                out["warnings"].append(EFFECT_GATE + ": instruction '" + c + " still calls '" + f.tool
                                       + "', which changes state outside the process. Make the instruction ACT.");
            }
        }
    }
    return out;
}

def _repair_writes(writes: list[EffectFinding], ir_text: str, skill_dir: str, name: str, spec: any, attempts: int,
                   out: dict[str, any]) -> list[any] {
    # The compile model's repair, then the mechanical relabel, for the tools that write
    # below ACT; adds to out's findings, notes, report and warnings.
    # -> [the IR, the tools whose callers are not warned about: rewritten, or left below ACT]
    msg: dict[str, str] = {};
    for f in writes {
        msg[f.tool] = (EFFECT_GATE + ": tool '" + f.tool + "' is labeled " + (f.surface or "(none)")
                       + ", but its code changes state outside the process: " + "; ".join(f.evidence)
                       + ". Label it ACT, or change the tool so it does not write.");
        out["findings"].append([EFFECT_GATE, msg[f.tool]]);
    }
    cur = ir_text;
    todo = [f.tool for f in writes];
    rewritten: list[str] = [];
    # The compile model first, for a bounded number of attempts. It only proposes: a
    # candidate is adopted when _judge_repair says so.
    tried = 0;
    while _EFFECT_LLM_PINNED and todo and tried < attempts {
        tried += 1;
        cand = "";
        try {
            cand = _unfence(str(repair_effects(cur, "\n".join([msg[t] for t in todo]))));
        } except Exception as e {
            out["report"].append(EFFECT_GATE + ": repair attempt " + str(tried) + " failed (" + str(e)[:120] + ")");
            break;
        }
        cand = _keep_instruction_surfaces(cand, cur);
        j = _judge_repair(cand, cur, name, skill_dir, spec, todo);
        if not j["ok"] {
            out["report"].append(EFFECT_GATE + ": repair attempt " + str(tried) + " by the compile model not adopted: " + str(j["why"]));
            continue;
        }
        cur = cand;
        for (t, how) in j["fixed"].items() {
            out["notes"].append("repair: " + EFFECT_GATE + " the compile model fixed tool '" + t + "' (" + how
                                + ", attempt " + str(tried) + ")");
            if how != "relabeled ACT" { rewritten.append(t); }
        }
        todo = [t for t in todo if t not in j["fixed"]];
    }
    # What the model did not fix is relabeled mechanically. Refuse only if the relabel
    # is what breaks lowering, or it costs the proof: an IR that did not lower before is
    # the compile gate's (and repair's) business, with the honest label.
    left = [f for f in writes if f.tool in todo];
    if left {
        fixed = relabel_act(cur, [f.tool for f in left]);
        mod_cur = _lower(cur, name);
        mod_fixed = _lower(fixed, name) if fixed else "";
        if fixed and (mod_fixed or (not mod_cur)) and _proof_kept(spec, fixed, cur) {
            cur = fixed;
            for f in left {
                out["notes"].append("autofix: " + EFFECT_GATE + " relabeled tool '" + f.tool + "' " + (f.surface or "(none)")
                                    + " -> ACT; its code changes state outside the process: " + "; ".join(f.evidence)
                                    + " [found by " + f.source + "]"
                                    + (("; the compile model did not fix it in " + str(tried) + " attempt(s)") if tried else ""));
                # An ACT tool's path parameters bind write-side when a COMPUTE instruction
                # calls it (compiler.jac, _bind_args), so the relabel can change what the
                # call passes. It may fix a destination or break a read: say which call changed.
                was_calls = sorted(_calls(mod_cur, f.tool)) if mod_cur else [];
                now_calls = sorted(_calls(mod_fixed, f.tool)) if mod_fixed else [];
                if mod_cur and mod_fixed and was_calls != now_calls {
                    gone = [c for c in was_calls if c not in now_calls];
                    came = [c for c in now_calls if c not in was_calls];
                    w = (EFFECT_GATE + ": relabeling tool '" + f.tool + "' ACT changes how it is called: "
                         + ("; ".join(gone[:2]) or "(no call)") + " -> " + ("; ".join(came[:2]) or "(no call)")
                         + ". Check that the tool still gets the paths it reads.");
                    out["warnings"].append(w);
                    out["call_changes"].append(w);
                }
            }
        } else {
            for f in left {
                out["warnings"].append(EFFECT_GATE + ": tool '" + f.tool + "' changes state outside the process (" + "; ".join(f.evidence)
                                       + "), but relabeling it ACT breaks lowering or the faithfulness proof; the label stays "
                                       + (f.surface or "(none)") + ". Label it ACT and fix the binding, or remove the write.");
                rewritten.append(f.tool);
            }
        }
    }
    return [cur, rewritten];
}

def _judge_repair(cand_text: str, cur_text: str, name: str, skill_dir: str, spec: any, targets: list[str]) -> dict[str, any] {
    # -> {"ok": adopt it?, "why": the reason when not, "fixed": {tool: how}}
    out: dict[str, any] = {"ok": False, "why": "", "fixed": {}};
    cand: any = None;
    try { cand = _load_ir(cand_text); } except Exception { cand = None; }
    if not (isinstance(cand, dict) and isinstance(cand.get("tools"), dict)) {
        out["why"] = "the reply is not an AG-IR";
        return out;
    }
    cur = _load_ir(cur_text);
    for t in targets {
        how = _how_fixed(cand, cur, t, skill_dir);
        if how { out["fixed"][t] = how; }
    }
    before = _scan_writes(cur, skill_dir);
    added = [t for t in _scan_writes(cand, skill_dir) if t not in before];
    was_calls = _bad_calls(cur, skill_dir);
    new_calls = [c for c in _bad_calls(cand, skill_dir) if c not in was_calls];
    if not out["fixed"] {
        out["why"] = "no finding fixed";
    } elif added {
        out["why"] = "it labels another writing tool below ACT: " + ", ".join(added);
    } elif new_calls {
        out["why"] = "it makes an instruction call a writing tool it may not: " + "; ".join(new_calls[:3]);
    } elif (not _lowers(cand_text, name)) and _lowers(cur_text, name) {
        out["why"] = "it no longer lowers";
    } elif not _proof_kept(spec, cand_text, cur_text) {
        out["why"] = "the faithfulness proof got worse";
    } else {
        out["ok"] = True;
    }
    return out;
}

def _how_fixed(cand: dict[str, any], cur: dict[str, any], tool: str, skill_dir: str) -> str {
    # How a candidate settles the finding on `tool`; "" when it does not.
    t = (cand.get("tools") or {}).get(tool);
    if not isinstance(t, dict) { return "removed the tool"; }
    t = _as_lowered(tool, t);
    if str(t.get("surface") or "").startswith("ACT") { return "relabeled ACT"; }
    o = _as_lowered(tool, (cur.get("tools") or {}).get(tool) or {});
    code = str(t.get("body") or "") + str(t.get("command") or "");
    if code != (str(o.get("body") or "") + str(o.get("command") or "")) {
        # A tool left with no code is not a read-only rewrite: lowering gives it a script
        # the model writes at run time (compiler.jac, embodiment ladder rung 3).
        s = scan_tool(t, skill_dir);
        if s["code"] and (not s["writes"]) and (not s["unknown"]) { return "rewrote it so it no longer writes"; }
    }
    return "";
}

def _scan_writes(ir: dict[str, any], skill_dir: str) -> list[str] {
    # non-ACT tools the scan alone says write
    out: list[str] = [];
    tools = ir.get("tools") or {};
    if not isinstance(tools, dict) { return out; }
    for (name, raw) in tools.items() {
        t = _as_lowered(str(name), raw);
        if isinstance(t, dict) and (not str(t.get("surface") or "").startswith("ACT")) and scan_tool(t, skill_dir)["writes"] {
            out.append(str(name));
        }
    }
    return out;
}

def _bad_calls(ir: dict[str, any], skill_dir: str) -> list[str] {
    # "'id' (OPCODE) calls 'tool'" for each instruction that calls a tool the scan alone
    # says writes and whose opcode may not call it (_bad_callers): a repair must not add one
    out: list[str] = [];
    tools = ir.get("tools") or {};
    if not isinstance(tools, dict) { return out; }
    for (name, raw) in tools.items() {
        t = _as_lowered(str(name), raw);
        if not (isinstance(t, dict) and scan_tool(t, skill_dir)["writes"]) { continue; }
        surface = str(t.get("surface") or "");
        for c in _callers(ir, str(name)) {
            op = str(c.get("type") or "");
            if _bad_callers(surface, [op]) { out.append("'" + str(c.get("id")) + "' (" + op + ") calls '" + str(name) + "'"); }
        }
    }
    return out;
}

def _proof_kept(spec: any, cand_text: str, cur_text: str) -> bool {
    if spec is None { return True; }
    return gap_score(faithfulness_report(spec, cand_text)) <= gap_score(faithfulness_report(spec, cur_text));
}

def _observe_callers_in(ir_text: str, tool: str) -> list[str] {
    # "id (OPCODE)" for each instruction that calls `tool` and is still OBSERVE or COMPUTE
    ir = _load_ir(ir_text);
    if not isinstance(ir, dict) { return []; }
    tools = ir.get("tools") or {};
    t = _as_lowered(tool, tools.get(tool) if isinstance(tools, dict) else None);
    surface = str(t.get("surface") or "") if isinstance(t, dict) else "";
    return [str(c.get("id")) + "' (" + str(c.get("type")) + ")" for c in _callers(ir, tool)
            if len(_bad_callers(surface, [str(c.get("type") or "")])) > 0];
}

def effect_recheck(old_ir: str, new_ir: str, skill_dir: str, name: str, spec: any = None, asked: int = 0) -> any {
    # A later stage (compile repair) replaced the IR the rung checked. Run the rung again,
    # without repair attempts, when a tool's code or surface, or a caller's opcode, changed.
    # `asked`: the model reader's budget already spent in this compile.
    # -> the rung's result, or None when nothing the gate reads changed.
    if _effect_view(old_ir) == _effect_view(new_ir) { return None; }
    return effect_rung(new_ir, skill_dir, name, spec, 0, asked);
}

def effect_after_repair(er: dict[str, any], new_ir: str, skill_dir: str, name: str, spec: any = None) -> any {
    # raise2: compile repair replaced the IR that the rung `er` checked. Check the new IR
    # again (effect_recheck) and keep a relabel only if it still compiles.
    # -> None when nothing the gate reads changed, else {"ir_text": the IR to keep,
    #    "verdict": compile_gate's verdict on it when that is a relabel (else None),
    #    "warnings": the effect warnings for it, "repairs": repair-ladder lines}
    r = effect_recheck(str(er["ir_text"]), new_ir, skill_dir, name, spec, int(er.get("asked") or 0));
    if r is None { return None; }
    out: dict[str, any] = {"ir_text": new_ir, "verdict": None, "repairs": list(r["report"]) + list(r["notes"]),
                           "warnings": []};
    # The first rung's warnings described the IR before the repair; those that still hold
    # come from the recheck. A call or a terminal report the first rung changed is history and stays.
    warnings: list[str] = [str(w) for w in list(er.get("call_changes") or []) + list(er.get("report_changes") or [])];
    if str(r["ir_text"]) != new_ir {
        v2 = compile_gate(str(r["ir_text"]), name);
        if v2.ok {
            out["ir_text"] = str(r["ir_text"]);
            out["verdict"] = v2;
        } else {
            warnings.append(EFFECT_GATE + ": the compile repair left a tool labeled below what its code does, "
                            + "and relabeling it ACT does not compile; the label stays.");
        }
    }
    for w in list(r["warnings"]) { if str(w) not in warnings { warnings.append(str(w)); } }
    out["warnings"] = warnings;
    return out;
}

def _effect_view(ir_text: str) -> list[any] {
    # what the gate reads: each tool's code and surface, and each instruction's opcode and
    # what binds it to a tool (its id, `tool`, `procedure`, and the tools' `serves`)
    ir: any = None;
    try { ir = _load_ir(ir_text); } except Exception { return ["unreadable", ir_text]; }
    if not isinstance(ir, dict) { return ["unreadable", ir_text]; }
    tools = ir.get("tools") or {};
    out: list[any] = [];
    if isinstance(tools, dict) {
        for k in sorted(tools.keys(), key=str) {
            t = tools[k];
            if isinstance(t, dict) {
                out.append([str(k), str(t.get("surface") or ""), str(t.get("body") or ""), str(t.get("command") or ""),
                            [str(x) for x in list(t.get("serves") or [])]]);
            } else { out.append([str(k), str(t)]); }
        }
    }
    for c in list(ir.get("nodes") or []) {
        if isinstance(c, dict) {
            out.append([str(c.get("id")), str(c.get("type") or ""), str(c.get("tool") or ""), str(c.get("procedure") or "")]);
        }
    }
    return out;
}

def _unfence(text: str) -> str {
    # strip an accidental markdown fence despite the sem, as repair_compile_loop does
    t = str(text or "").strip();
    if t.startswith("```") {
        lines = t.splitlines()[1:];
        if lines and lines[-1].strip().startswith("```") { lines = lines[:-1]; }
        t = "\n".join(lines);
    }
    return t;
}
