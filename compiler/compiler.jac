"""AG-IR -> OSP transpiler (the LOWER step, mechanized) — native Jac.

Reads an `agent.ir` (YAML; the typed graph, four views) and emits an `agent.jac`
(OSP: nodes + edges + walker) per the lowering table in
docs/skill-to-agent-pipeline.md Part B. It lowers the IR *as written* into a
compiling, runnable scaffold — it does NOT reproduce the post-hoc, benchmark-
hardened tool bodies of the hand-lowered production agents (those bug-fixes are
not in the IR and are out of scope for a mechanical transpile).

Written in pure Jac, importing Python stdlib directly. The *generated* agents
keep `::py::` for verbatim tool bodies — the faithful "run the skill's
prescribed snippet, can't drift" choice (pipeline B.4).

Public API (used by the playground backend):
    transpile_ir(ir_text: str, name: str) -> str        # IR YAML -> .jac source

CLI / test harness:
    jac run transpiler.jac                               # transpile every agent*.ir in the repo
"""

import os;
import re;
import glob;
import textwrap;
import traceback;
import yaml;

glob GEN_TYPES: list = ["GEN-RAW", "GEN-ENUM", "GEN-FILL", "GEN-EDIT"];

# Embodiment-ladder rung-3 fallbacks recorded during a transpile: tools with no
# runnable body that were lowered to the scoped GEN-RAW author-run envelope instead
# of a silent `pass`. Reset per _transpile; reported by _main (loud, not silent).
glob _FALLBACKS: list = [];

# Jac/Python reserved words that must not be emitted as bare identifiers.
glob RESERVED: list = [
    "True", "False", "None", "and", "or", "not", "in", "is", "if", "else",
    "elif", "for", "while", "def", "class", "return", "import", "from", "as",
    "walker", "node", "edge", "obj", "has", "can", "with", "visit", "spawn",
    "report", "root", "global", "nonlocal", "lambda", "del", "try", "except",
    "async", "await", "yield", "pass", "enum", "sem", "here", "self", "visitor"
];

# binding convention: agent.ir tool-body bare-names -> OpArgs accessors (pdf §tools)
glob BIND: dict = {
    "input": "args.inputs[0] if args.inputs else None",
    "inputs": "args.inputs",
    "out": "_clean_path(args.output_spec.path)",
    "out_dir": "_clean_path(args.output_spec.path)",
    "out_prefix": "_clean_path(args.output_spec.path)",
    "layout": "False"
};

# ---------------------------------------------------------------------------
# coercion + string helpers — keep everything `any` to dodge dict/list generics
# ---------------------------------------------------------------------------
def _list(x: any) -> any {
    return x if x else [];
}

def _dict(x: any) -> any {
    return x if x else {};
}

# normalize a value (None | str | list) to a list[str]
def _aslist(x: any) -> list {
    if x is None { return []; }
    if isinstance(x, list) { return [str(i) for i in x]; }
    return [str(x)];
}

def _items(d: any) -> any {
    r = [];
    dd = d if d else {};
    for k in dd { r.append([k, dd[k]]); }
    return r;
}

def _j(sep: str, items: any) -> str {
    return sep.join([str(x) for x in items]);
}

def _camel(s: any) -> str {
    parts = [p for p in re.split(r"[^0-9a-zA-Z]+", str(s)) if p];
    out = "";
    for p in parts { out += str(p).capitalize(); }
    return out;
}

def _safe(s: any) -> str {
    r = str(re.sub(r"[^0-9a-zA-Z_]", "_", str(s)));
    if r and r[0:1].isdigit() { r = "_" + r; }
    if r in RESERVED { r = r + "_"; }
    return r;
}

# Node archetype name from a node id. Must not collide with a TYPE name
# (an `obj`/`enum`), or `node X {}` clashes with `obj X {}` (E0077). e.g.
# mcp-builder has node id `plan` AND type `Plan`.
def _arch(nid: any, types: any) -> str {
    c = _camel(nid);
    if c in list(types) { return c + "Nd"; }
    return c;
}

# A cognitive slot is named after its node; if that collides with a walker carry
# of the same name, prefix it so the module def and the field don't shadow.
def _slot_name(nid: any, carries: any) -> str {
    s = _safe(nid);
    if s in list(carries) { return "gen_" + s; }
    return s;
}

def _q(s: any) -> str {
    t = "" if s is None else str(s);
    t = t.replace("\\", "\\\\");
    t = t.replace("\"", "\\\"");
    t = t.replace("\n", " ");
    t = t.replace("\r", " ");
    return "\"" + t + "\"";
}

def _block_lit(s: any) -> str {
    t = "" if s is None else str(s);
    t = t.replace("\\", "\\\\");
    t = t.replace("\"\"\"", "\\\"\\\"\\\"");
    return "\"\"\"" + t + "\"\"\"";
}

# Relaxer — the hand-authored .ir files use loose YAML (unquoted flow-map values
# with commas, `key:{` without a space). Quote flat inline mappings line-by-line
# WITHOUT touching block-scalar code (those lines don't match the field shape).
def _relax_line(line: str) -> str {
    ln = re.sub(r"(\S):\{", r"\1: {", line);
    m: any = re.match(r"^(\s*[\w\".\-]+\s*):\s*\{(.*)\}\s*$", ln);
    if not m { return ln; }
    head = str(m.group(1));
    inner = str(m.group(2));
    # Already-valid flow maps (quoted values, nested braces) must be left alone.
    try { yaml.safe_load("{" + inner + "}"); return ln; }
    except Exception {  }
    parts: any = re.split(r",(?=\s*[\w\"]+\s*:)", inner);
    fixed: list = [];
    for p in parts {
        if ":" not in p { fixed.append(p.strip()); continue; }
        kv: any = p.partition(":");
        k = str(kv[0]).strip();
        v = str(kv[2]).strip();
        if v and (v[0] not in "\"'[{") { v = "'" + v.replace("'", "''") + "'"; }
        fixed.append(f"{k}: {v}");
    }
    joined = _j(", ", fixed);
    return f"{head}: {{ {joined} }}";
}

def _relax(text: str) -> str {
    return _j("\n", [_relax_line(l) for l in text.splitlines()]);
}

# Sanitize a sig param token to a valid Python identifier (sigs sometimes use
# CLI-ish notation: `[out_prefix]`, `[--cols N]`, `model_id?`).
def _param(nm: any) -> str {
    r = str(re.sub(r"[^0-9a-zA-Z_]", "_", str(nm))).strip("_");
    if not r { return "_arg"; }
    if r[0:1].isdigit() { r = "_" + r; }
    return r;
}

def _parse_sig(sig: any) -> list {
    if not sig { return [[], "any"]; }
    m: any = re.match(r"\s*\((.*?)\)\s*(->\s*(.*))?$", str(sig).strip());
    if not m { return [[], "any"]; }
    params_raw = str(m.group(1)).strip();
    ret = str(m.group(3) or "any").strip();
    params: list = [];
    if params_raw {
        for p in params_raw.split(",") {
            raw = p.split("=")[0].split(":")[0].strip();   # drop default + type ann
            nm = _param(raw);
            if nm and (nm not in params) { params.append(nm); }
        }
    }
    return [params, ret];
}

# IR type string -> [jac_type, default_expr]. Honors B.2 (no `T|None`; sentinels).
def _jac_type(tstr: any, types: any) -> list {
    if tstr is None { return ["any", "None"]; }
    t = str(tstr).strip().rstrip("?").strip();
    base = t.split("[")[0].split("|")[0].strip();
    if base in types {
        kind = types[base].get("kind");
        if kind == "enum" {
            members = _list(types[base].get("members") or ["OTHER"]);
            m0 = members[0];
            return [base, f"{base}.{m0}"];
        }
        return [base, f"{base}()"];
    }
    me: any = re.match(r"enum\{(.+)\}", t);
    if me {
        first = str(me.group(1)).split(",")[0].strip();
        return ["str", _q(first)];
    }
    ml: any = re.match(r"list\[(.+)\]", t);
    if ml {
        inner = str(ml.group(1)).strip();
        ib = inner.split("|")[0].strip();
        if ib == "int" { return ["list[int]", "[]"]; }
        if ib in ["str", "path"] { return ["list[str]", "[]"]; }
        if ib in types { return [f"list[{ib}]", "[]"]; }
        return ["list[any]", "[]"];
    }
    if "|" in t { return ["any", "None"]; }
    mapping: dict = {
        "str": ["str", "\"\""], "path": ["str", "\"\""],
        "int": ["int", "0"], "float": ["float", "0.0"],
        "bool": ["bool", "False"], "any": ["any", "None"], "dict": ["dict", "{}"]
    };
    if t in mapping { return list(mapping[t]); }
    return ["any", "None"];
}

def _bind_arg(param: any, arg_fields: any) -> str {
    p = str(param);
    pl = p.lower();
    if p in BIND { return str(BIND[p]); }
    if p in arg_fields { return f"args.{p}"; }
    # CHANGE (binding layer): fuzzy-match a tool param to an OpArgs field or a command
    # literal, so pipeline/command dispatch threads real data instead of None.
    if pl.startswith("input") or pl in ["src", "source"] { return "(args.inputs[0] if args.inputs else None)"; }
    if pl.startswith("original") { return "(args.inputs[0] if args.inputs else None)"; }
    if pl.startswith("output") or pl in ["out", "dest", "outfile", "filename", "file"] { return "_clean_path(args.output_spec.path)"; }
    if pl.startswith("unpacked") { return "\"unpacked/\""; }
    # strip a trailing _<ext>/_dir/_path and retry against the fields/BIND.
    base = re.sub(r"_(pptx|docx|xlsx|pdf|md|html|js|dir|path|file)$", "", pl);
    if base != pl {
        if base in arg_fields { return f"args.{base}"; }
        if base in BIND { return str(BIND[base]); }
        if base.startswith("input") { return "(args.inputs[0] if args.inputs else None)"; }
        if base.startswith("output") { return "_clean_path(args.output_spec.path)"; }
    }
    return "None";
}

# Bind a tool param to a WALKER-CARRY expression for faithful node-level dispatch:
#   carry of that name        -> self.<carry>
#   field of an object carry  -> self.<carry>.<field>   (e.g. width -> self.spec.width)
#   field of the OpArgs carry  -> self.args.<field>
#   otherwise                 -> None
# This threads real data (frames, builder, spec.width, …) node-to-node instead of
# routing everything through the args-only dispatcher (which passes None for data).
def _bind_carry_arg(param: any, carries: any, types: any) -> str {
    p = str(param);
    ck = list(carries);
    if p in ck { return "self." + _safe(p); }
    for kv in _items(carries) {
        cname = str(kv[0]);
        c = kv[1];
        if not isinstance(c, dict) { continue; }
        base = str(c.get("type", "")).split("[")[0].split("|")[0].strip();
        if (base in types) and (types[base].get("kind") == "object") {
            for fkv in _items(types[base].get("fields")) {
                if str(fkv[0]) == p { return "self." + _safe(cname) + "." + _safe(p); }
            }
        }
    }
    return "None";
}

# Standard: a TERMINAL node serializes the produced carries into `report`, never a
# constant. Build `f"<name>[{enum}] k=v ..."` over the enum/op carry + deliverable
# carries (writes of ACT·artifact nodes, plus common output names).
def _terminal_report(name: any, ir: any, carries: any, types: any) -> str {
    ck = list(carries);
    enumc = "";
    for kv in _items(carries) {
        c = kv[1];
        if not isinstance(c, dict) { continue; }
        base = str(c.get("type", "")).split("[")[0].split("|")[0].strip();
        if (base in types) and (types[base].get("kind") == "enum") { enumc = str(kv[0]); break; }
    }
    deliv: list = [];
    for nn in _list(ir.get("nodes")) {
        if not isinstance(nn, dict) { continue; }
        if (str(nn.get("type", "")) == "ACT") and ("artifact" in str(nn.get("surface", ""))) {
            for w in _list(nn.get("writes")) {
                if (w in ck) and (str(w) != "report") and (str(w) not in deliv) { deliv.append(str(w)); }
            }
        }
    }
    for nm in ["artifact", "deliverable", "result", "comm", "eval_xml", "package_path", "showcase", "valid"] {
        if (nm in ck) and (nm not in deliv) { deliv.append(nm); }
    }
    head = str(name) + (("[{self." + _safe(enumc) + "}]") if enumc else "");
    parts: list = [head];
    # Surface each delivered carry's CONTENT (via _artifact_text), not its file path —
    # delivery ops return the path of what the script wrote; the caller wants the answer.
    for d in deliv[:4] { parts.append(str(d) + "={_artifact_text(self." + _safe(str(d)) + ")}"); }
    if (not enumc) and (not deliv) { return "f\"" + str(name) + " done\""; }
    return "f\"" + _j(" ", parts) + "\"";
}

# Find the tool (by surface prefix) whose `serves` lists this node -> [name, params].
def _serving_tool(ir: any, nid: any, surf_prefix: str) -> any {
    for kv in _items(ir.get("tools")) {
        t = kv[1];
        if not isinstance(t, dict) { continue; }
        if not str(t.get("surface", "")).startswith(surf_prefix) { continue; }
        if nid in list(_list(t.get("serves"))) {
            return [str(kv[0]), _parse_sig(t.get("sig"))[0]];
        }
    }
    return [];
}

# Resolve the tool bound to a node (any surface): the node's explicit `tool:`, else a
# tool whose `serves` lists this node id. Returns [name, params] or [].
def _node_tool(ir: any, nid: any, nd: any) -> any {
    tools = _dict(ir.get("tools"));
    tname = nd.get("tool") if isinstance(nd, dict) else None;
    # a node's `tool:` may be a list (multi-tool node) -> not hashable for `in tools`;
    # collapse to the first named tool, and only probe dict membership with a str.
    if isinstance(tname, list) { tname = tname[0] if tname else None; }
    if isinstance(tname, str) and (tname in tools) { return [str(tname), _parse_sig(tools[tname].get("sig"))[0]]; }
    # tool whose `serves` lists this node
    for kv in _items(tools) {
        t = kv[1];
        if isinstance(t, dict) and (nid in list(_list(t.get("serves")))) {
            return [str(kv[0]), _parse_sig(t.get("sig"))[0]];
        }
    }
    # tool whose NAME matches the node id (common 1:1 convention, e.g. node
    # `aggregate` <-> tool `aggregate`)
    if nid in tools { return [str(nid), _parse_sig(tools[nid].get("sig"))[0]]; }
    return [];
}

# Standard write-assignment for a code-tool dispatch whose ::py:: return is Unknown:
# str carry -> str-wrap, list carry -> list(), any -> direct, typed obj/enum -> run
# but keep default (a mechanical py return can't be assigned to a typed obj).
def _assign_carry(tgt: any, expr: str, carries: any, types: any) -> str {
    if (not tgt) or (tgt not in list(carries)) { return "        " + expr + ";"; }
    tt = str(_jac_type(carries[tgt].get("type"), types)[0]);
    if tt == "str" { return f"        self.{_safe(str(tgt))} = str({expr});"; }
    if tt == "any" { return f"        self.{_safe(str(tgt))} = {expr};"; }
    if tt.startswith("list") { return f"        self.{_safe(str(tgt))} = list({expr});"; }
    return f"        {expr};  # -> {tgt} ({tt}); carry keeps default";
}

# Bind a tool's params to carry expressions. Hybrid: by-NAME/field first (so a
# param `width` binds to `self.spec.width`), else POSITIONAL to the node's `reads`
# (so a param `gif_path` binds to reads[0]=`artifact` -> `self.artifact`). This
# handles both the "fields of a spec" and "renamed positional" tool conventions.
def _bind_args(params: any, reads: any, carries: any, types: any) -> str {
    rl: list = list(_list(reads));
    ck = list(carries);
    out: list = [];
    i = 0;
    for p in _list(params) {
        b = _bind_carry_arg(p, carries, types);
        if (b == "None") and (i < len(rl)) and (rl[i] in ck) { b = "self." + _safe(str(rl[i])); }
        out.append(b);
        i += 1;
    }
    return _j(", ", out);
}

def _shared_helpers() -> str {
    here = os.path.dirname(os.path.abspath(__file__));
    p = os.path.join(here, "assets", "osp_runtime.py.txt");
    if os.path.exists(p) {
        with open(p) as f { return str(f.read()); }
    }
    return "";
}

# ---------------------------------------------------------------------------
# IR loading
# ---------------------------------------------------------------------------
def _load_ir(text: str) -> any {
    fm: any = {};
    body = text;
    if text.lstrip().startswith("---") {
        t = text.lstrip();
        end = t.find("\n---", 3);
        if end != -1 {
            fm_text = t[3:end];
            body = t[end + 4:];
            try { fm = yaml.safe_load(fm_text) or {}; }
            except Exception { fm = {}; }
        }
    }
    ir: any = yaml.safe_load(_relax(body)) or {};
    if not isinstance(ir, dict) { ir = {}; }
    if "_frontmatter" not in ir { ir["_frontmatter"] = fm; }
    return ir;
}

# ---------------------------------------------------------------------------
# section emitters
# ---------------------------------------------------------------------------
def _dispatcher_lines(fnname: str, toollist: any, arg_fields: any) -> list {
    lines: list = ["", f"def {fnname}(op_name, args):"];
    # CHANGE 2 — operation = ordered pipeline. Group tools by served op (preserving IR
    # order = pipeline order). A single-tool op is a direct return; a multi-tool op runs
    # its steps in sequence over the shared workspace and returns the last. (Was: one
    # `if op==X: return tool()` per (tool,op) pair -> duplicate keys, only the first ran.)
    ops: list = [];
    by_op: dict = {};
    for entry in toollist {
        tn = entry[0]; params = entry[1]; serves = entry[2];
        bound = _j(", ", [_bind_arg(p, arg_fields) for p in params]);
        for op in serves {
            if str(op) not in by_op { by_op[str(op)] = []; ops.append(str(op)); }
            by_op[str(op)].append([_safe(str(tn)), bound]);
        }
    }
    for op in ops {
        steps = by_op[op];
        if len(list(steps)) == 1 {
            lines.append(f"    if op_name == \"{op}\": return _{steps[0][0]}({steps[0][1]})");
        } else {
            lines.append(f"    if op_name == \"{op}\":");
            k = 0;
            for st in steps {
                if k == len(list(steps)) - 1 {
                    lines.append(f"        return _{st[0]}({st[1]})");
                } else {
                    lines.append(f"        _{st[0]}({st[1]})");
                }
                k += 1;
            }
        }
    }
    # unknown op -> no-op, never raise (grounding: a missing branch must not crash the walker)
    lines.append("    return None");
    return lines;
}

# A tool body in the IR is the verbatim snippet, but NOT always Python — some are
# shell commands (pandoc/soffice/qpdf), CSS, or JSON templates. Emitting those as a
# Python function body breaks compilation. Detect + lower them so the agent loads.
def _py_ok(code: str) -> bool {
    import ast;
    try {
        ast.parse("def _f():\n" + textwrap.indent(code, "    "));
        return True;
    } except Exception { return False; }
}

glob _SHELL_CLIS: list = ["pandoc", "soffice", "libreoffice", "qpdf", "pdftoppm", "pdfimages",
    "pdftotext", "tesseract", "pnpm", "npm ", "npx", "create-vite", "bash ", "sh ", "cp ",
    "mv ", "tar ", "mkdir ", "rm ", "convert ", "gs ", "./"];

def _looks_shell(body: str) -> bool {
    for ln in body.splitlines() {
        s = ln.strip();
        if (not s) or s.startswith("#") { continue; }
        for c in _SHELL_CLIS { if s.startswith(c) { return True; } }
    }
    return False;
}

def _body_lines(body: str) -> list {
    out: list = [];
    if _py_ok(body) {
        for ln in body.splitlines() { out.append(("    " + ln) if ln.strip() else ""); }
        return out;
    }
    if _looks_shell(body) {
        cmds: list = [];
        for ln in body.splitlines() {
            s = ln.strip();
            if s and (not s.startswith("#")) { cmds.append(s); }
        }
        script = "\n".join(cmds);
        out.append("    # non-Python tool body (shell) -> subprocess");
        out.append("    import subprocess as _sp");
        out.append("    _r = _sp.run(" + repr(script) + ", shell=True, capture_output=True, text=True)");
        out.append("    return _r.stdout if _r.returncode == 0 else _r.stderr");
    } else {
        out.append("    # non-Python tool body (CSS/JSON/template) -> returned string");
        out.append("    return " + repr(body));
    }
    return out;
}

# Rung-2: extract the FIXED prefix of a bundle command (executable + script/module),
# stopping at the first `.py` script or `-m <module>`; the tool's params become the
# trailing args. First line only, inline `#` comment stripped.
def _cmd_prefix(cmd: any) -> list {
    first = str(cmd or "").splitlines()[0] if str(cmd or "").strip() else "";
    first = str(first).split("#")[0].strip();
    toks: list = [tk for tk in first.split(" ") if tk];
    pfx: list = [];
    i = 0;
    while i < len(toks) {
        tk = str(toks[i]);
        pfx.append(tk);
        if tk.endswith(".py") { return pfx; }
        if tk == "-m" and (i + 1) < len(toks) { pfx.append(str(toks[i + 1])); return pfx; }
        i += 1;
    }
    # no script/module -> a bare CLI (pandoc, soffice, qpdf): just the executable.
    return [str(toks[0])] if toks else [];
}

# Rung-0: does this tool read/write the outside world at runtime (unscriptable)?
def _is_live_tool(name: any, surf: any) -> bool {
    n = str(name).lower();
    for pat in ["read_slack", "read_email", "read_drive", "read_calendar", "web_fetch",
                "web_search", "ask_user", "gh_get"] {
        if pat in n { return True; }
    }
    if n.endswith("_api") or n.endswith("_fetch") or n.endswith("_search") { return True; }
    return False;
}

def _emit_tools(ir: any) -> str {
    out: list = ["::py::", "import os, sys, json as _json, subprocess as _subprocess, glob as _glob, tempfile"];
    sense_tools: list = [];
    act_tools: list = [];
    for kv in _items(ir.get("tools")) {
        name = kv[0];
        t = kv[1];
        if not isinstance(t, dict) { continue; }
        sig = _parse_sig(t.get("sig"));
        params = sig[0];
        surf = str(t.get("surface", ""));
        body = textwrap.dedent(str(t.get("body") or "")).rstrip();
        if not body.strip() {
            # EMBODIMENT LADDER (never a silent `pass`): rung 2 command -> rung 1 writer
            # -> rung 0 live-tool -> rung 3 scoped author.
            ppar = ""; cpar = ""; spar = "";
            if surf.startswith("ACT") {
                for p in params {
                    pl = str(p).lower();
                    if (not ppar) and (("path" in pl) or (pl in ["out", "dest", "file", "outfile", "filename"])) { ppar = _safe(str(p)); }
                    elif (not cpar) and (("content" in pl) or ("text" in pl) or ("data" in pl) or ("body" in pl) or ("code" in pl) or ("source" in pl)) { cpar = _safe(str(p)); }
                    if str(p) in ["output_spec", "args", "spec", "output"] { spar = _safe(str(p)); }
                }
            }
            cmd = str(t.get("command") or "").strip();
            pfx = _cmd_prefix(cmd) if cmd else [];
            # author-run detection from the RAW command: `<runner> <bare-file.(js|py)>` (2 toks,
            # second is a bare script filename) -> the tool receives program CONTENT, not a path.
            traw: list = [tk for tk in str(cmd).splitlines()[0].split("#")[0].split(" ") if tk] if cmd else [];
            tgt = str(traw[1]) if len(list(traw)) == 2 else "";
            is_author_run = (tgt != "") and (tgt.endswith(".js") or tgt.endswith(".py")) and ("/" not in tgt) and (tgt != "op.py");
            if cmd and is_author_run {
                # CHANGE 3 author-run: write the program CONTENT to the target, then run it
                # (returns {ok,error,out} for an author-loop). Fixes `node program.js` where
                # the arg was content, not a path.
                runner = _q(str(traw[0]));
                cpar2 = _safe(str(params[0])) if params else "None";
                body = f"return _run_program({runner}, {_q(tgt)}, {cpar2})";
            } elif cmd and pfx {
                # RUNG 2: synthesize the bundle-command as a deterministic subprocess call.
                pfx_lit = "[" + _j(", ", [_q(x) for x in pfx]) + "]";
                args_lit = "[" + _j(", ", [_safe(str(p)) for p in params]) + "]";
                body = f"return _run_cmd({pfx_lit}, {args_lit})";
            } elif surf.startswith("ACT") and ppar and cpar {
                body = f"return _write_artifact(str({cpar}), _clean_path({ppar}))";
            } elif surf.startswith("ACT") and ("artifact" in surf) {
                c0 = cpar if cpar else (_safe(str(params[0])) if params else "None");
                if (not spar) and (len(list(params)) > 1) { spar = _safe(str(params[1])); }
                if not spar { spar = "None"; }
                body = f"return _emit_surface({c0}, {spar})";
            } elif _is_live_tool(name, surf) {
                # RUNG 0: live-integration tool -> real fetch or honest sentinel, never scripted.
                _FALLBACKS.append(str(name) + "(live)");
                args_lit2 = "[" + _j(", ", [_safe(str(p)) for p in params]) + "]";
                body = f"return _live_tool({_q(str(name))}, {args_lit2})";
            } else {
                # EMBODIMENT LADDER rung 3: no runnable body -> a SCOPED GEN-RAW author-run
                # envelope (never a silent `pass`). Context = tool doc + bound inputs; the
                # runner authors a script for this job, runs it, verifies, re-authors on fail.
                _FALLBACKS.append(str(name));
                doc = str(t.get("doc") or "");
                job = str(name) + ((": " + doc) if doc else "");
                ctx = _q(job) + " + \"\\nInputs:\"";
                for p in params { ctx = ctx + " + \" " + _safe(str(p)) + "=\" + str(" + _safe(str(p)) + ")"; }
                outp = ppar if ppar else "None";
                body = f"return _scoped_author_run({ctx}, {outp})";
            }
        }
        # Default every param to None: byLLM/LLMs sometimes emit a tool call with
        # missing args; a required positional would raise TypeError ("missing
        # argument") and the model retries blindly. With defaults, the body's own
        # guards return a helpful message instead, so the model self-corrects.
        sig_params = _j(", ", [(_safe(p) + "=None") for p in params]) if params else "";
        out.append("");
        out.append(f"def _{_safe(name)}({sig_params}):");
        for fl in _body_lines(body) { out.append(fl); }
        serves = _list(t.get("serves"));
        if surf == "SENSE" { sense_tools.append([name, params, serves]); }
        elif surf.startswith("ACT") { act_tools.append([name, params, serves]); }
    }
    arg_fields: list = [];
    for kv2 in _items(ir.get("types")) {
        td = kv2[1];
        if isinstance(td, dict) and td.get("kind") == "object" {
            for fkv in _items(td.get("fields")) { arg_fields.append(fkv[0]); }
        }
    }
    if sense_tools { out += _dispatcher_lines("_run_sense", sense_tools, arg_fields); }
    if act_tools { out += _dispatcher_lines("_run_act", act_tools, arg_fields); }
    out.append(_shared_helpers());
    out.append("::py::");
    return _j("\n", out);
}

# Typed Jac wrappers + `sem` for the autonomy (ReAct) tools a GEN slot exposes.
# byLLM builds the tool schema from these — a bare ::py:: impl with =None params
# and no docstring yields a weak/optional schema, so the model fumbles (empty
# {} calls, or guessing the arg key like `code`). A typed REQUIRED param + a sem
# description makes the call deterministic. The wrapper just forwards to the impl.
def _emit_tool_wrappers(ir: any) -> str {
    autos: list = [];
    for n in _list(ir.get("nodes")) {
        if not isinstance(n, dict) { continue; }
        au = _dict(n.get("autonomy"));
        for tt in _list(au.get("tools")) {
            if (str(tt) != "SENSE") and (str(tt) not in autos) { autos.append(str(tt)); }
        }
    }
    tools = _dict(ir.get("tools"));
    out: list = [];
    for tn in autos {
        t = tools.get(tn);
        params = _parse_sig(t.get("sig"))[0] if isinstance(t, dict) else [];
        sig = _j(", ", [(_safe(p) + ": str") for p in params]);
        callargs = _j(", ", [_safe(p) for p in params]);
        out.append(f"def {_safe(tn)}({sig}) -> str {{ return str(_{_safe(tn)}({callargs})); }}");
        doc = (t.get("doc") if isinstance(t, dict) else "") or ("invoke the " + str(tn) + " tool");
        out.append(f"sem {_safe(tn)} = {_q(doc)};");
    }
    return _j("\n", out);
}

def _emit_knowledge(ir: any) -> str {
    out: list = [];
    for kv in _items(ir.get("knowledge")) {
        name = kv[0];
        k = kv[1];
        if not isinstance(k, dict) { continue; }
        for key in ["pattern", "template", "fix", "body"] {
            if k.get(key) {
                gname = _safe(name).upper();
                out.append(f"glob {gname}: str =\n{_block_lit(k[key])};");
                break;
            }
        }
    }
    return _j("\n", out);
}

def _emit_types(ir: any) -> str {
    out: list = [];
    types = ir.get("types");
    for kv in _items(types) {
        name = kv[0];
        t = kv[1];
        if not isinstance(t, dict) { continue; }
        kind = t.get("kind");
        if kind == "enum" {
            members = _list(t.get("members"));
            out.append(f"enum {name} {{ {_j(', ', members)} }}");
            if t.get("doc") { out.append(f"sem {name} = {_q(t['doc'])};"); }
        } elif kind == "object" {
            out.append(f"obj {name} {{");
            for fkv in _items(t.get("fields")) {
                fname = fkv[0];
                f = fkv[1];
                ftype = f.get("type") if isinstance(f, dict) else f;
                jt = _jac_type(ftype, types);
                ft = jt[0];
                fd = jt[1];
                # obj fields feed byLLM structured output — it cannot generate a
                # schema for `any` (typing.Any). Demote to a typed str so GEN-FILL
                # over this obj works (unions like "path|str|?" land here).
                if ft == "any" { ft = "str"; fd = "\"\""; }
                elif "any" in ft { ft = ft.replace("any", "str"); }   # list[any]/dict[..,any] also break byLLM schema
                out.append(f"    has {_safe(fname)}: {ft} = {fd};");
            }
            out.append("}");
            if t.get("doc") { out.append(f"sem {name} = {_q(t['doc'])};"); }
            for fkv2 in _items(t.get("fields")) {
                fname2 = fkv2[0];
                f2 = fkv2[1];
                if isinstance(f2, dict) and f2.get("doc") {
                    out.append(f"sem {name}.{_safe(fname2)} = {_q(f2['doc'])};");
                }
            }
        }
    }
    return _j("\n", out);
}

def _node_index(ir: any) -> dict {
    types = ir.get("types");
    idx: dict = {};
    for n in _list(ir.get("nodes")) {
        if isinstance(n, dict) and n.get("id") {
            idx[n["id"]] = [_arch(n["id"], types), n];
        }
    }
    return idx;
}

# Gather the knowledge items RESIDENT on a node and fold their doc + code
# pattern into the slot prompt, so the GEN-RAW author actually SEES the owned
# helpers / scaffolds (e.g. `from core.gif_builder import GIFBuilder`) and imports
# them instead of reinventing them. This is the "knowledge sits on the node" half.
# Render any knowledge value (str / list / dict) to text so NOTHING is truncated.
def _render_val(v: any) -> str {
    if v is None { return ""; }
    if isinstance(v, str) { return str(v); }
    if isinstance(v, list) {
        rows: list = [];
        for x in v { rows.append("- " + _render_val(x)); }
        return _j("\n", rows);
    }
    if isinstance(v, dict) {
        rows2: list = [];
        for kv in v.items() { rows2.append(str(kv[0]) + ": " + _render_val(kv[1])); }
        return _j("\n", rows2);
    }
    return str(v);
}

# Render a full knowledge entry — doc + EVERY content sub-field (pattern, value,
# items, rules, presets, axes, must_be, constraints, dimensions, …). The previous
# version emitted only doc + one code field, truncating the real payload to headers
# / line-pointers (the #3 grounding gap).
def _render_knowledge(name: any, k: any) -> str {
    parts: list = [];
    if k.get("doc") { parts.append(str(k.get("doc"))); }
    for kv in k.items() {
        key = str(kv[0]);
        if key in ["resident_on", "doc", "modality", "summary_for"] { continue; }
        rv = _render_val(kv[1]);
        if rv.strip() { parts.append(key + ":\n" + rv); }
    }
    return "[" + str(name) + "]\n" + _j("\n", parts);
}

def _slot_seed(ir: any, nid: any) -> str {
    blocks: list = [];
    for kv in _items(ir.get("knowledge")) {
        k = kv[1];
        if not isinstance(k, dict) { continue; }
        if nid not in list(_aslist(k.get("resident_on"))) { continue; }
        blocks.append(_render_knowledge(str(kv[0]), k));
    }
    if not blocks { return ""; }
    return "\n\nResources resident on this node — USE these (owned helpers must be imported, not reinvented; rules/data are authoritative):\n\n" + _j("\n\n", blocks);
}

# Build a slot's call-args. Slot params are demoted `any`->`str` (byLLM can't
# schematize Any), but the walker carry `has` stays `any`; so a scalar-`any` carry
# passed straight in fails Jac's checker (E1053 Any->str). Cast those at the call.
def _slot_args(creads: any, carries: any, types: any) -> str {
    parts: list = [];
    for r in creads {
        c = carries.get(r) if isinstance(carries, dict) else None;
        # cast on the JAC-MAPPED type (what the carry `has` becomes): anything that
        # lowers to `any` (bare `any`, unions like `path | str`, etc.) is demoted to a
        # `str` slot param, so the `any` carry needs a str() cast at the call.
        jt = str(_jac_type(c.get("type"), types)[0]) if isinstance(c, dict) else "";
        if "any" in jt { parts.append(f"str(self.{_safe(r)})"); }
        else { parts.append(f"self.{_safe(r)}"); }
    }
    return _j(", ", parts);
}

def _emit_slots(ir: any) -> str {
    out: list = [];
    types = ir.get("types");
    wlk = _dict(ir.get("walker"));
    carries = _dict(wlk.get("carries"));
    for n in _list(ir.get("nodes")) {
        if not isinstance(n, dict) { continue; }
        nt = str(n.get("type", ""));
        no = str(n.get("owner", ""));
        # Emit a by-llm slot for every node the walker invokes as cognition: all
        # Mind nodes, CALL sub-agents, and owner=model Boundary/Flow nodes that
        # PRODUCE a carry and have no bound code-tool.
        is_slot = (nt in GEN_TYPES) or (nt == "CALL");
        if (not is_slot) and (nt in ["SENSE", "ACT", "LOOP", "ROUTE"]) and (no == "model") and n.get("writes") and (not _node_tool(ir, n["id"], n)) {
            is_slot = True;
        }
        if not is_slot { continue; }
        slot = _slot_name(n["id"], carries);
        creads = [r for r in _list(n.get("reads")) if r in list(carries)][:6];
        if (nt == "CALL") and (not creads) and ("task" in list(carries)) { creads = ["task"]; }
        params: list = [];
        for r in creads {
            jt = _jac_type(carries[r].get("type"), types);
            pt = str(jt[0]);
            if "any" in pt { pt = pt.replace("any", "str"); }   # byLLM can't schematize Any
            params.append(f"{_safe(r)}: {pt}");
        }
        outt = n.get("output");
        ret = "str";
        if nt == "CALL" {
            ret = "str";
        } elif outt and (outt in types) {
            ret = str(outt);
        } elif n.get("writes") {
            wf = _list(n.get("writes"))[0];
            if wf in carries { jt2 = _jac_type(carries[wf].get("type"), types); ret = str(jt2[0]); }
        }
        if "any" in ret { ret = ret.replace("any", "str"); }   # byLLM can't schematize Any in a slot return
        tools = "";
        au = _dict(n.get("autonomy"));
        if isinstance(au, dict) and au.get("tools") {
            real = [tt for tt in _list(au.get("tools")) if tt != "SENSE"];
            if real {
                names = _j(", ", [_safe(tt) for tt in real]);
                tools = f"(tools=[{names}])";
            }
        }
        psig = _j(", ", params);
        out.append(f"def {slot}({psig}) -> {ret} by llm{tools};");
        seed = _slot_seed(ir, n["id"]);
        doc = str(n.get("doc") or "");
        semtext = doc + seed;
        if semtext.strip() {
            if seed { out.append(f"sem {slot} =\n{_block_lit(semtext)};"); }
            else { out.append(f"sem {slot} = {_q(semtext)};"); }
        }
    }
    # error escape hatch: a repair slot any script-running node falls back to when
    # the authored script crashes at runtime (see _exec_repair_lines).
    if "script" in list(carries) {
        out.append("def repair_script(script: str, error: str) -> str by llm;");
        out.append("sem repair_script = \"The authored script failed at runtime with the given error. Return a COMPLETE, corrected, self-contained replacement script that fixes the error (and only what the error requires) — output runnable code only, no prose, no markdown fences.\";");
    }
    return _j("\n", out);
}

# Use the guard's OWN field name (the IR guard names the routing field, e.g.
# `mode in {...}`) so we route on the carry that actually exists.
def _guard_to_cond(guard: any, member_to_enum: any) -> str {
    g = str(guard).strip();
    m: any = re.match(r"(\w+)\s+in\s+\{(.+)\}", g);
    if m {
        fld = _safe(m.group(1));
        members = [x.strip() for x in str(m.group(2)).split(",") if x.strip()];
        terms: list = [];
        for mem in members {
            en = member_to_enum.get(mem, "");
            terms.append(f"{en}.{mem}" if en else _q(mem));
        }
        joined = _j(", ", terms);
        return f"self.{fld} in [{joined}]";
    }
    m2: any = re.match(r"(\w+)\s*==\s*(\w+)", g);
    if m2 {
        fld2 = _safe(m2.group(1));
        mem2 = str(m2.group(2));
        en2 = member_to_enum.get(mem2, "");
        return (f"self.{fld2} == {en2}.{mem2}") if en2 else (f"self.{fld2} == {_q(mem2)}");
    }
    return "True";
}

# General guard -> Jac boolean expression. Handles enum-in, comparisons over carry
# paths (`spec.optimize_for_size == true`, `recalc.status == "errors_found"`,
# `build_attempts < 2`), and bare/negated carries. Falls back to True (advance) so
# an unparseable guard never breaks compilation.
def _guard_expr(g: any, m2e: any) -> str {
    s = str(g).strip();
    mi: any = re.match(r"(\w+)\s+in\s+\{(.+)\}$", s);
    if mi {
        fld = _safe(mi.group(1));
        terms: list = [];
        for mem in [x.strip() for x in str(mi.group(2)).split(",") if x.strip()] {
            en = m2e.get(mem, "");
            terms.append(f"{en}.{mem}" if en else _q(mem));
        }
        return f"self.{fld} in [{_j(', ', terms)}]";
    }
    mc: any = re.match(r"(not\s+)?([A-Za-z_][\w.]*)\s*(==|!=|>=|<=|>|<)\s*(.+)$", s);
    if mc {
        neg = "not " if mc.group(1) else "";
        left = "self." + str(mc.group(2));
        op = str(mc.group(3));
        rt: str = str(mc.group(4)).strip();
        # Take only the leading token of the RHS — IR guards often carry an inline
        # parenthetical/prose comment, e.g. `pages > 1 (user requested more)`. Keep
        # `1`, drop the rest, so a numeric/enum RHS doesn't get quoted as a string.
        if not (rt.startswith("\"") or rt.startswith("'")) {
            rt = str(re.split(r"[\s(]", rt, 1)[0]);
        }
        rl = rt.lower();
        rv = "";
        if rl == "true" { rv = "True"; }
        elif rl == "false" { rv = "False"; }
        elif rt.startswith("\"") or rt.startswith("'") { rv = rt; }
        elif re.match(r"^-?\d+(\.\d+)?$", rt) { rv = rt; }
        elif rt in m2e { rv = str(m2e[rt]) + "." + str(rt); }
        else { rv = _q(rt); }
        return f"{neg}{left} {op} {rv}";
    }
    mb: any = re.match(r"(not\s+)?([A-Za-z_][\w.]*)$", s);
    if mb {
        neg = "not " if mb.group(1) else "";
        return neg + "self." + str(mb.group(2));
    }
    return "True";
}

# Emit OSP control flow for a node from its out-edges + guards. Guarded edges ->
# if/elif conditional visits; a total else advances to a forward default; unguarded
# self-loops are never followed unconditionally (would be an infinite loop).
def _emit_flow(out_edges: any, nid: any, nidx: any, m2e: any) -> list {
    lines: list = [];
    guarded: list = [];
    fwd_default = "";
    first_fwd = "";
    sentinels = ["", "otherwise", "default", "else", "always", "true", "_"];
    for e in out_edges {
        ti = nidx.get(e.get("to"));
        if not ti { continue; }
        tgt = str(ti[0]);
        g = str(e.get("guard") or "");
        real = g if (g.strip().lower() not in sentinels) else "";
        if real { guarded.append([real, tgt]); }
        if str(e.get("to")) != str(nid) {
            if not first_fwd { first_fwd = tgt; }
            if (not real) and (not fwd_default) { fwd_default = tgt; }
        }
    }
    deflt = fwd_default if fwd_default else first_fwd;
    if guarded {
        i = 0;
        for gp in guarded {
            gpp: any = gp;
            kw = "if" if i == 0 else "elif";
            lines.append(f"        {kw} {_guard_expr(gpp[0], m2e)} {{ visit [-->][?:{gpp[1]}]; }}");
            i += 1;
        }
        if deflt { lines.append(f"        else {{ visit [-->][?:{deflt}]; }}"); }
        else { lines.append("        else { disengage; }"); }
    } elif deflt {
        # no guards: advance to the forward target (avoids following any self-loop)
        lines.append(f"        visit [-->][?:{deflt}];");
    } else {
        lines.append("        visit [-->];");
    }
    return lines;
}

# Error escape hatch: run the authored script, and on failure hand the error back
# to the model (repair_script, by llm) to fix THAT step, retry (bounded), then
# resume. Returns the walker lines that replace a bare `_exec_script(...)` call.
def _exec_repair_lines(tgt: any, aarg: str, tt: str) -> list {
    asn = "";
    if tgt and ((tt == "str") or (tt == "any")) { asn = "self." + _safe(str(tgt)) + " = str(_r[\"path\"]); "; }
    return [
        "        _att = 0; _ok = False;",
        "        while (_att <= 2) and (not _ok) {",
        "            _r = _exec_script_try(self.script" + aarg + ");",
        "            if _r[\"ok\"] { " + asn + "_ok = True; }",
        "            elif _att < 2 { self.script = str(_strip_fences(repair_script(self.script, str(_r[\"error\"])))); }",
        "            _att += 1;",
        "        }"
    ];
}

def _emit_walker(ir: any) -> list {
    wlk = _dict(ir.get("walker"));
    fm = _dict(ir.get("_frontmatter"));
    name = wlk.get("name") or (_camel(fm.get("name", "agent")) + "Agent");
    carries = _dict(wlk.get("carries"));
    types = ir.get("types");
    nidx = _node_index(ir);
    edges = _list(ir.get("edges"));

    member_to_enum: dict = {};
    for kv in _items(types) {
        td = kv[1];
        if isinstance(td, dict) and td.get("kind") == "enum" {
            for mem in _list(td.get("members")) { member_to_enum[mem] = kv[0]; }
        }
    }

    out: list = [f"walker {name} {{"];
    # Only `task` is provided by the harness (run(task, model, skill)); it is the
    # one no-default field and must come first (Jac E2004). EVERY other carry —
    # even role:input ones — gets a default so `Agent(task=task)` constructs.
    out.append("    has task: str;");
    for kv2 in _items(carries) {
        if kv2[0] == "task" { continue; }
        c2 = kv2[1];
        jt2 = _jac_type(c2.get("type"), types);
        out.append(f"    has {_safe(kv2[0])}: {jt2[0]} = {jt2[1]};");
    }
    # Auto-declare route fields named in guards but not carried (IR gaps, e.g.
    # gh-issues routes on `mode` which it never lists as a carry). Keeps it
    # compiling; the field defaults to None so an undefined route falls through.
    ckeys = list(carries);
    gflds: list = [];
    for e0 in edges {
        g0 = e0.get("guard");
        if not g0 { continue; }
        gm: any = re.match(r"\s*(\w+)\s*(?:in|==)\s", str(g0));
        if gm {
            gf = _safe(gm.group(1));
            if (gf not in ckeys) and (gf not in gflds) and (gf != "task") { gflds.append(gf); }
        }
    }
    for gf2 in gflds {
        out.append(f"    has {gf2}: any = None;");
        ckeys.append(gf2);
    }
    out.append("    has report: str = \"\";");
    out.append("");

    route_field = "op";
    for kv3 in _items(carries) {
        c3 = kv3[1];
        base = str(c3.get("type", "")).split("[")[0].strip();
        if (base in types) and types[base].get("kind") == "enum" { route_field = str(kv3[0]); break; }
    }

    for n in _list(ir.get("nodes")) {
        if not isinstance(n, dict) { continue; }
        nid = n["id"];
        arch = _arch(nid, types);
        ntype = n.get("type");
        owner = n.get("owner");
        writes = _list(n.get("writes"));
        reads = _list(n.get("reads"));
        out_edges = [e for e in edges if e.get("from") == nid];
        out.append(f"    can n_{_safe(nid)} with {arch} entry {{");
        out.append(f"        _progress({_q(nid)});");   # live: mark current node

        if ntype == "TERMINAL" {
            out.append(f"        self.report = {_terminal_report(name, ir, carries, types)};");
            out.append("        disengage;");
            out.append("    }");
            out.append("");
            continue;
        }

        body: list = [];
        can_dispatch = ("args" in ckeys) and (route_field in ckeys);
        if ntype in GEN_TYPES {
            creads = [r for r in reads if r in ckeys][:6];
            call_args = _slot_args(creads, carries, types);
            call = f"{_slot_name(nid, carries)}({call_args})";
            tgt = writes[0] if writes else None;
            if tgt and (tgt in ckeys) {
                tt = _jac_type(carries[tgt].get("type"), types)[0];
                val = call;
                if (ntype == "GEN-RAW") and (tt == "str") { val = f"str(_strip_fences({call}))"; }
                body.append(f"        self.{_safe(tgt)} = {val};");
                # author+execute fold: a GEN-RAW that writes a `script` carry needs
                # the authored code RUN so the deliverable is produced.
                if (ntype == "GEN-RAW") and (tgt == "script") {
                    # Does the node own a run_*/exec autonomy tool?
                    au_fold = _dict(n.get("autonomy"));
                    runtool = "";
                    for tt in _list(au_fold.get("tools")) {
                        tl = str(tt).lower();
                        if ("run" in tl) or ("exec" in tl) { runtool = "_" + _safe(str(tt)); }
                    }
                    if runtool {
                        # Tool-owning author: byLLM lets the model EITHER return the
                        # script as the slot value OR drive the run-tool with it (it
                        # often does the former and calls the tool with empty args).
                        # Feed the slot's authored script through the node's own
                        # run-tool and capture its RESULT into the node's data carry
                        # (e.g. frames), so the downstream assemble/emit nodes can
                        # thread it into the deliverable — faithful node separation.
                        datacarry = "";
                        for w3 in writes {
                            if (str(w3) != "script") and (w3 in ckeys) and (not datacarry) {
                                dt = _jac_type(carries[w3].get("type"), types)[0];
                                if str(dt).startswith("list") { datacarry = str(w3); }
                            }
                        }
                        if datacarry {
                            # The run-tool's return is the by-llm loop's feedback (a
                            # status string), and the model's final message often
                            # isn't the script. Prefer the data the tool STASHED
                            # during the loop; fall back to re-deriving from the
                            # final authored script.
                            body.append(f"        self.{_safe(datacarry)} = list(_unstash({_q(datacarry)}) or _exec_var(self.script, {_q(datacarry)}));");
                        } else {
                            body.append(f"        {runtool}(self.script);");
                        }
                    } else {
                        # No run-tool: run the script directly (e.g. xlsx author_create).
                        aarg = ", self.args" if ("args" in ckeys) else "";
                        artW = "";
                        for w2 in writes {
                            if (w2 != "script") and (w2 in ckeys) and (not artW) { artW = str(w2); }
                        }
                        if artW {
                            w2t = str(_jac_type(carries[artW].get("type"), types)[0]);
                            for fl in _exec_repair_lines(artW, aarg, w2t) { body.append(fl); }
                        }
                    }
                }
            } else {
                body.append(f"        {call};");
            }
        } elif (ntype == "ROUTE") and (owner == "code") {
            branches: list = [];
            default_target = "";
            for e in out_edges {
                tinfo = nidx.get(e.get("to"));
                if not tinfo { continue; }
                tgt2 = tinfo[0];
                g = e.get("guard");
                if g { branches.append([_guard_to_cond(g, member_to_enum), tgt2]); }
                else { default_target = str(tgt2); }
            }
            for (i, br) in enumerate(branches) {
                brc: any = br;
                kw = "if" if i == 0 else "elif";
                body.append(f"        {kw} {brc[0]} {{ visit [-->][?:{brc[1]}]; }}");
            }
            if default_target {
                if branches { body.append(f"        else {{ visit [-->][?:{default_target}]; }}"); }
                else { body.append(f"        visit [-->][?:{default_target}];"); }
            }
            if (not branches) and (not default_target) { body.append("        visit [-->];"); }
        } elif (ntype == "ROUTE") and (owner == "model") {
            # a model ROUTE that PRODUCES a carry (e.g. route_format -> spec) is a
            # GEN step + branch: call its slot, assign, then route.
            if writes and (not _node_tool(ir, nid, n)) {
                slot = _slot_name(nid, carries);
                creadsR = [r for r in reads if r in ckeys][:6];
                callR = f"{slot}({_slot_args(creadsR, carries, types)})";
                body.append(_assign_carry(writes[0], callR, carries, types));
            }
            if len(out_edges) > 1 {
                body.append("        visit [-->] by llm(incl_info={\"task\": self.task});");
            } else {
                body.append("        visit [-->];");
            }
        } elif (ntype == "SENSE") and (owner == "code") {
            tgt3 = writes[0] if writes else None;
            st3 = _node_tool(ir, nid, n);
            if st3 {
                expr3 = "_" + _safe(str(st3[0])) + "(" + _bind_args(st3[1], reads, carries, types) + ")";
                body.append(_assign_carry(tgt3, expr3, carries, types));
            } elif can_dispatch and tgt3 and (tgt3 in ckeys) {
                body.append(f"        self.{_safe(tgt3)} = _run_sense(self.{route_field}.name, self.args);");
            } else {
                body.append(f"        # SENSE {nid} (no recognized tool dispatch)");
            }
        } elif (ntype == "SENSE") and (owner == "model") {
            # bounded cognitive fetch: a by-llm slot (may ReAct over autonomy.tools)
            tgt3m = writes[0] if writes else None;
            slot = _slot_name(nid, carries);
            creads3 = [r for r in reads if r in ckeys][:6];
            call3 = f"{slot}({_slot_args(creads3, carries, types)})";
            body.append(_assign_carry(tgt3m, call3, carries, types));
        } elif ntype == "ACT" {
            tgt5 = writes[0] if writes else "artifact";
            # ::py:: dispatcher returns are Unknown: assign only to str (str-wrapped)
            # or `any` carries; for a typed obj/list carry, run the tool but leave the
            # carry at its default (a mechanical transpile can't type the py return).
            tt5 = "str";
            if tgt5 in ckeys { tt5 = str(_jac_type(carries[tgt5].get("type"), types)[0]); }
            canA = (tt5 == "str") or (tt5 == "any");
            wl = "str(" if (tt5 == "str") else "";
            wr = ")" if (tt5 == "str") else "";
            expr = "";
            exprlines: list = [];
            if ("script" in reads) and ("script" in ckeys) and (tgt5 in ckeys) {
                # run the authored script with the error escape hatch (repair + retry)
                aarg = ", self.args" if ("args" in ckeys) else "";
                exprlines = _exec_repair_lines(tgt5, aarg, tt5);
            } elif ("data" in reads) and ("data" in ckeys) and ("args" in ckeys) and (tgt5 in ckeys) {
                expr = "_emit(self.data, self.args)";
            } elif (owner == "code") and can_dispatch and (tgt5 in ckeys) {
                expr = "_run_act(self." + route_field + ".name, self.args)";
            }
            # Standard node-level dispatch: a tool bound to this node (its `tool:` or
            # a tool whose `serves` lists it) -> call it with carry-threaded args
            # (frames, builder, spec.width, …), realizing the IR's node separation.
            stA = _node_tool(ir, nid, n);
            if (not expr) and stA {
                expr = "_" + _safe(str(stA[0])) + "(" + _bind_args(stA[1], reads, carries, types) + ")";
            }
            if (not expr) and (owner == "model") {
                # ACT owner=model with no tool = a cognitive emit (e.g. report,
                # completion tips) -> a by-llm slot over its reads.
                slot = _slot_name(nid, carries);
                creads5 = [r for r in reads if r in ckeys][:6];
                expr = f"{slot}({_slot_args(creads5, carries, types)})";
            }
            # ACT·artifact with no tool but a str content carry it reads -> write it
            # to a deterministic run-dir file (app-controlled path).
            if (not expr) and ("artifact" in str(n.get("surface", ""))) {
                for rc in reads {
                    if (rc in ckeys) and (rc != "artifact") and (not expr) {
                        if str(_jac_type(carries[rc].get("type"), types)[0]) == "str" {
                            expr = f"_write_artifact(str(self.{_safe(str(rc))}), _outname(self.task, {_q(_safe(str(rc)) + '.out')}))";
                        }
                    }
                }
            }
            if exprlines { for el in exprlines { body.append(el); } }
            elif expr { body.append(_assign_carry(tgt5, expr, carries, types)); }
            else { body.append(f"        # ACT {nid} (no recognized tool dispatch)"); }
        } elif ntype == "CALL" {
            # CALL expands a sub-IR: lower its author slot (a by-llm sub-agent),
            # binding the SAME reads the slot declares, then exec the produced
            # script into the target's artifact carry.
            tgtc = writes[0] if writes else None;
            slot = _slot_name(nid, carries);
            ccreads = [r for r in reads if r in ckeys][:6];
            if (not ccreads) and ("task" in ckeys) { ccreads = ["task"]; }
            callc = f"{slot}({_slot_args(ccreads, carries, types)})";
            if "script" in ckeys {
                body.append(f"        self.script = str(_strip_fences({callc}));");
                ttc = str(_jac_type(carries[tgtc].get("type"), types)[0]) if (tgtc and (tgtc in ckeys)) else "str";
                for fl in _exec_repair_lines(tgtc, "", ttc) { body.append(fl); }
            } else {
                body.append(_assign_carry(tgtc, callc, carries, types));
            }
        } elif ntype == "LOOP" {
            # bounded revise/retry: author/produce, then advance (the back-edge guard
            # is lowered with the edges in Stage D). Emit the productive call.
            stL = _node_tool(ir, nid, n);
            if stL {
                expr = "_" + _safe(str(stL[0])) + "(" + _bind_args(stL[1], reads, carries, types) + ")";
                body.append(_assign_carry(writes[0] if writes else None, expr, carries, types));
            } elif owner == "model" {
                slot = _slot_name(nid, carries);
                creadsL = [r for r in reads if r in ckeys][:6];
                body.append(_assign_carry(writes[0] if writes else None, f"{slot}({_slot_args(creadsL, carries, types)})", carries, types));
            } else {
                body.append(f"        # LOOP {nid}");
            }
        } elif ntype == "SPAWN" {
            body.append(f"        # SPAWN {nid} — fork subagent walkers (TODO)");
        } elif ntype == "CODE" {
            stC = _node_tool(ir, nid, n);
            if stC {
                expr = "_" + _safe(str(stC[0])) + "(" + _bind_args(stC[1], reads, carries, types) + ")";
                body.append(_assign_carry(writes[0] if writes else None, expr, carries, types));
            } elif n.get("body") {
                tgtC = writes[0] if writes else None;
                inb = textwrap.dedent(str(n.get("body"))).strip();
                # inline single-expression CODE bodies (e.g. a dict lookup) as an assign
                if tgtC and ("\n" not in inb) and inb.startswith("self.") {
                    body.append("        " + inb + ";");
                } else {
                    body.append(f"        # CODE {nid} (inline body not lowerable)");
                }
            } else {
                body.append(f"        # CODE {nid}");
            }
        }

        has_flow = False;
        for b in body {
            if ("visit" in b) or ("disengage" in b) { has_flow = True; }
        }
        # Nodes that didn't emit their own flow (everything but ROUTE/TERMINAL) get
        # guard-aware OSP flow: guarded edges -> conditional visits, total else, and
        # no unconditional self-loop.
        if not has_flow {
            for fl in _emit_flow(out_edges, nid, nidx, member_to_enum) { body.append(fl); }
        }
        for b2 in body { out.append(b2); }
        out.append("    }");
        out.append("");
    }
    out.append("}");
    return [_j("\n", out), name];
}

def _emit_nodes(ir: any) -> str {
    types = ir.get("types");
    out: list = [];
    for n in _list(ir.get("nodes")) {
        if isinstance(n, dict) and n.get("id") { out.append(f"node {_arch(n['id'], types)} {{}}"); }
    }
    return _j("\n", out);
}

def _emit_run(ir: any, walker_name: any) -> str {
    types = ir.get("types");
    edges = _list(ir.get("edges"));
    nodes = _list(ir.get("nodes"));
    out: list = ["def run(task: str, model: Model, skill: str) -> str {", "    global llm;", "    llm = model;", ""];
    var: dict = {};
    for n in nodes {
        nid = n.get("id");
        if not nid { continue; }
        v = "n_" + _safe(nid);
        var[nid] = v;
        out.append(f"    {v} = {_arch(nid, types)}();");
    }
    out.append("");
    first = nodes[0]["id"] if nodes else "";
    if first { out.append(f"    root ++> {var[first]};"); }
    for e in edges {
        ef = e.get("from");
        et = e.get("to");
        if (ef in var) and (et in var) { out.append(f"    {var[ef]} ++> {var[et]};"); }
    }
    out.append("");
    if first {
        out.append(f"    agent = {var[first]} spawn {walker_name}(task=task);");
        out.append("    return agent.report;");
    } else {
        out.append("    return \"\";");
    }
    out.append("}");
    return _j("\n", out);
}

# ---------------------------------------------------------------------------
# top-level
# ---------------------------------------------------------------------------
def _transpile(ir_text: str, name: str, model_name: str = "") -> str {
    ir = _load_ir(ir_text);
    fm = _dict(ir.get("_frontmatter"));
    _FALLBACKS.clear();                 # embodiment-ladder fallbacks for THIS transpile
    tools_block = _emit_tools(ir);
    wk = _emit_walker(ir);
    walker_block = wk[0];
    walker_name = wk[1];

    parts: list = [];
    sk = fm.get("name", name);
    shape = ir.get("shape", "?");
    parts.append(f"\"\"\"OSP agent — transpiled from agent.ir by agir-playground/transpiler.jac.\n\nSkill: {sk}\nShape: {shape}\nMechanical lowering of the IR as written (not the hand-tuned production agent).\n\"\"\"");
    parts.append("import from jaclang.byllm.lib { Model }");
    parts.append(tools_block);
    kn = _emit_knowledge(ir);
    if kn { parts.append("# ===== KNOWLEDGE (static globs) =====\n" + kn); }
    mn = model_name if model_name else "gpt-4o-mini";
    parts.append(f"glob llm: Model = Model(model_name=\"{mn}\");");
    ty = _emit_types(ir);
    if ty { parts.append("# ===== TYPES =====\n" + ty); }
    tw = _emit_tool_wrappers(ir);
    if tw { parts.append("# ===== AUTONOMY TOOL WRAPPERS (typed + sem for byLLM) =====\n" + tw); }
    sl = _emit_slots(ir);
    if sl { parts.append("# ===== COGNITIVE SLOTS (GEN-*) =====\n" + sl); }
    if _FALLBACKS {
        # Rung-3 authoring slot for un-embodied tools (see _scoped_author_run). Scoped:
        # it receives only the tool's job + inputs, and returns a runnable script.
        gs: list = ["# ===== EMBODIMENT FALLBACK (scoped author for un-embodied tools) ====="];
        gs.append("def _gen_scoped(context: str) -> str by llm();");
        gs.append("sem _gen_scoped = \"You are given ONE specific sub-task and its inputs. Author a COMPLETE, self-contained Python script that performs exactly that sub-task and writes its output file(s) to the current working directory. Ground the script strictly in the described job; do not add unrelated steps. Return ONLY the script — no prose, no explanation, no markdown fences.\";");
        parts.append(_j("\n", gs));
    }
    parts.append("# ===== NODES =====\n" + _emit_nodes(ir));
    parts.append("# ===== WALKER =====\n" + walker_block);
    parts.append("# ===== ENTRYPOINT =====\n" + _emit_run(ir, walker_name));
    return _j("\n\n", parts) + "\n";
}

def transpile_ir(ir_text: str, name: str, model_name: str = "") -> str {
    return _transpile(ir_text, name, model_name);
}

# Detect an agent's INPUT SHAPE beyond the task text: does it expect an image
# and/or an input file? Signals: image/file-loading tools (load_image, read_*),
# and OpArgs/spec fields (image_path, input, inputs, file, source). Returns a list
# of {kind: 'image'|'file', label, hint} the studio renders as capture widgets.
def ir_input_shape(ir_text: str) -> list {
    try { ir = _load_ir(ir_text); } except Exception as ex { return []; }
    has_image = False;
    has_file = False;
    img_hint = "";
    file_hint = "";
    for kv in _items(ir.get("tools")) {
        n = str(kv[0]).lower();
        if "image" in n { has_image = True; img_hint = str(kv[0]); }
        elif ("read" in n) or ("load" in n) or ("unpack" in n) or ("extract" in n) {
            has_file = True; file_hint = str(kv[0]);
        }
    }
    for tkv in _items(ir.get("types")) {
        td = tkv[1];
        if not isinstance(td, dict) { continue; }
        for fkv in _items(td.get("fields")) {
            fl = str(fkv[0]).lower();
            if ("image" in fl) and (("path" in fl) or ("file" in fl) or (fl == "image")) { has_image = True; }
            if fl in ["input", "inputs", "file", "source_path", "in_path", "src"] { has_file = True; }
        }
    }
    wk = _dict(ir.get("walker"));
    for ckv in _items(wk.get("carries")) {
        cl = str(ckv[0]).lower();
        if cl in ["uploaded", "image", "img"] { has_image = True; }
    }
    out: list = [];
    if has_image { out.append({"kind": "image", "label": "Image (upload or paste)", "hint": img_hint or "the agent can use an uploaded image"}); }
    if has_file { out.append({"kind": "file", "label": "Input file", "hint": file_hint or "the agent reads an input file"}); }
    return out;
}

# Parse an IR into a plain node/edge graph (for the playground's visualizer).
# Returns {ok, error, name, shape, nodes:[{id,type,owner,doc,surface}], edges:[...]}.
def ir_graph(ir_text: str) -> dict {
    try {
        ir = _load_ir(ir_text);
    } except Exception as ex {
        return {"ok": False, "error": str(ex), "name": "", "shape": "", "nodes": [], "edges": []};
    }
    nodes: list = [];
    for n in _list(ir.get("nodes")) {
        if isinstance(n, dict) {
            au = _dict(n.get("autonomy"));
            nodes.append({
                "id": str(n.get("id", "")), "type": str(n.get("type", "")),
                "owner": str(n.get("owner", "")), "doc": str(n.get("doc", "")),
                "surface": str(n.get("surface", "")), "output": str(n.get("output", "")),
                "tool": str(n.get("tool", "")), "autonomy": _aslist(au.get("tools")),
                "reads": _aslist(n.get("reads")), "writes": _aslist(n.get("writes"))
            });
        }
    }
    edges: list = [];
    for e in _list(ir.get("edges")) {
        if isinstance(e, dict) {
            edges.append({
                "from": str(e.get("from", "")), "to": str(e.get("to", "")),
                "modality": str(e.get("modality", "")), "guard": str(e.get("guard", ""))
            });
        }
    }
    # dataflow source: each carried datum + the node(s) that produce it
    carries: list = [];
    wk = _dict(ir.get("walker"));
    for kv in _items(wk.get("carries")) {
        c = kv[1];
        pb = c.get("produced_by") if isinstance(c, dict) else None;
        carries.append({"name": str(kv[0]), "produced_by": _aslist(pb)});
    }
    # context/knowledge source: each static knowledge item + the nodes it sits on
    # + its FULL embodied content (the SKILL.md know-how crystallized into the IR).
    knowledge: list = [];
    for kv2 in _items(ir.get("knowledge")) {
        k = kv2[1];
        ro = k.get("resident_on") if isinstance(k, dict) else None;
        kcontent = _render_knowledge(str(kv2[0]), k) if isinstance(k, dict) else "";
        knowledge.append({"name": str(kv2[0]), "resident_on": _aslist(ro), "content": kcontent});
    }
    # tools — the deterministic surface; which node each serves + its signature
    tools: list = [];
    for kv3 in _items(ir.get("tools")) {
        t = kv3[1];
        if isinstance(t, dict) {
            tools.append({
                "name": str(kv3[0]), "surface": str(t.get("surface", "")),
                "serves": _aslist(t.get("serves")), "sig": str(t.get("sig", ""))
            });
        }
    }
    fm = _dict(ir.get("_frontmatter"));
    return {
        "ok": True, "error": "", "name": str(fm.get("name", "")),
        "shape": str(ir.get("shape", "")), "nodes": nodes, "edges": edges,
        "carries": carries, "knowledge": knowledge, "tools": tools
    };
}

def _repo_root() -> str {
    here = os.path.dirname(os.path.abspath(__file__));
    return os.path.dirname(here);
}

def _main() {
    repo = _repo_root();
    out_dir = os.path.join(repo, "agir-playground", "generated");
    os.makedirs(out_dir, exist_ok=True);
    irs = sorted(glob.glob(os.path.join(repo, "**", "agent*.ir"), recursive=True));
    print(f"found {len(irs)} agent.ir files\n");
    ok = 0;
    for p in irs {
        rel = os.path.relpath(p, repo);
        skill = os.path.basename(os.path.dirname(p));
        base = os.path.basename(p).replace("agent", "").replace(".ir", "").strip(".");
        gen_name = skill + (("_" + base) if base else "");
        try {
            with open(p) as f { src = _transpile(str(f.read()), gen_name); }
            with open(os.path.join(out_dir, gen_name + ".jac"), "w") as f2 { f2.write(src); }
            fb = "" if not _FALLBACKS else f"   [embodiment-fallback: {len(_FALLBACKS)} un-embodied tool(s) -> scoped author: {_j(', ', _FALLBACKS)}]";
            print(f"  [gen]  {rel}  ->  generated/{gen_name}.jac{fb}");
            ok += 1;
        } except Exception as ex {
            print(f"  [FAIL] {rel}: {str(ex)}");
            traceback.print_exc();
        }
    }
    print(f"\ntranspiled {ok}/{len(irs)} (jac check separately to verify compile)");
}

with entry:__main__ {
    _main();
}
