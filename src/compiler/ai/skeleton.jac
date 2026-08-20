"""Skeleton-first authoring, Phase 0 — mechanical, no LLM.

The one-shot author must hold every rule of a skill in one context and emit a
complete AG-IR. Past a few dozen rules it stops being able to: either it drops
mandates (the gate then refuses to eject) or it "covers" them by pointing a
handful of generic nodes at dozens of rule ids (the gate passes, and the agent
does none of it at run time).

Both are failures of the same step: asking a model to achieve COMPLETENESS.
Completeness is mechanical — `faith.required_shape` already says exactly what
shape each rule kind demands, and the gate's own drop messages spell out the
missing stub. This module inverts that function: one correctly-shaped stub per
required rule, so completeness holds BY CONSTRUCTION. The model's job shrinks to
what it is actually good at — filling stubs in with content, region by region.

Binding is SPECIFIC, not generic. `Rule.quote` is the verbatim skill span, so a
rule that says "Run `scripts/completeness_checker.py`" carries the artifact path
in its own text: the stub is bound to THAT script mechanically. This is what
makes embodiment provable instead of hoped-for.
"""

import os;
import yaml;

import from .spec_loop { Rule, RuleSet }
import from .lift_types { RuleKind, Modality, Cohesion }
import from .faith { RealShape, required_shape }

::py::
import re as _re

# Bundle artifacts a rule's verbatim quote names. Restricted to real bundle
# sub-directories so prose like "see the docs/ folder" does not mint a binding.
_ART_RE = _re.compile(
    r"((?:scripts|references|templates|examples|assets|data|mcp)/[A-Za-z0-9_.\-]+"
    r"\.(?:py|sh|js|ts|md|json|ya?ml|csv|txt|docx|xlsx|pptx))"
)
# An explicit invocation ("python3 scripts/x.py", "bash scripts/y.sh") tells us
# the artifact is EXECUTED rather than read.
_RUN_RE = _re.compile(
    r"(?:python3?|bash|sh|node|npx)\s+((?:scripts|bin)/[A-Za-z0-9_.\-]+\.[A-Za-z0-9]{1,4})"
)


def _artifacts(text):
    """(read_artifacts, run_artifacts) named verbatim in a rule quote."""
    t = str(text or "")
    run = []
    for m in _RUN_RE.finditer(t):
        if m.group(1) not in run:
            run.append(m.group(1))
    read = []
    for m in _ART_RE.finditer(t):
        a = m.group(1)
        if a in run or a in read:
            continue
        # a .py/.sh named as a step is executed even without an explicit runner
        if a.split(".")[-1] in ("py", "sh") and ("run" in t.lower() or "execute" in t.lower()):
            run.append(a)
        else:
            read.append(a)
    return read, run


def _safe(s, prefix="n"):
    out = _re.sub(r"[^A-Za-z0-9_]", "_", str(s or "")).strip("_").lower()
    if not out:
        out = "x"
    if not out[0].isalpha():
        out = prefix + "_" + out
    return out[:48]


def _short(s, n=110):
    t = " ".join(str(s or "").split())
    return t if len(t) <= n else t[: n - 1] + "…"


# The build-out phases find their work by this marker in a node/tool doc. It rides
# inside `doc` on purpose: the IR schema has no free-form keys, and an unknown key
# would either be dropped by the parsers or confuse the lowering.
_TODO = "  [TODO:"


def _todo(doc, what):
    return doc + _TODO + " " + what + "]"


def _mk_stub(rid, shape, statement, quote, condition, cohesion):
    """One stub spec. Artifact binding is read out of the rule's VERBATIM quote."""
    read, run = _artifacts(quote)
    return {"rid": rid, "shape": shape, "statement": statement, "quote": quote,
            "condition": condition, "cohesion": cohesion,
            "read_artifacts": read, "run_artifacts": run}


def _run_tool(art):
    """A code tool that genuinely executes a bundle script."""
    runner = "bash" if art.endswith(".sh") else "python3"
    return {
        "surface": "ACT·artifact",
        "sig": "(target) -> str",
        "command": runner + " " + art + " {target}",
        "doc": "Run " + art + " (bundle script named by the skill) and return its output.",
    }


def _read_tool(art):
    """A code tool that genuinely reads a bundle reference/template."""
    return {
        "surface": "SENSE",
        "sig": "() -> str",
        "body": "with open(" + repr(art) + ") as f:\n    return f.read()\n",
        "doc": "Read " + art + " (bundle file named by the skill) verbatim.",
    }


def emit_yaml(stubs, name, description, sub_resources):
    """Build the skeleton AG-IR document from ordered stub specs.

    stubs: list of dicts {rid, shape, statement, quote, condition, cohesion,
                          read_artifacts, run_artifacts}
    Emission is deterministic: same spec in, byte-identical skeleton out.
    """
    nodes, edges, tools, knowledge = [], [], {}, {}
    carries = {"task": {"type": "str", "role": "input", "doc": "user task verbatim"}}
    last_node = None
    pending_constraints = []          # folded into the next node authored

    def _attach_constraints(node):
        if not pending_constraints:
            return
        extra = " Constraints: " + " ".join(c["statement"] or c["quote"] for c in pending_constraints)
        node["doc"] = (node.get("doc", "") + extra)[:900]
        for c in pending_constraints:
            node["traces_to"].append(c["rid"])
        del pending_constraints[:]

    # NOTE: no untraced "activate" preamble node. check_soundness treats any
    # non-TERMINAL node with an empty traces_to as ADDED behavior — a skeleton
    # must not manufacture its own soundness violation.
    for s in stubs:
        rid, shape = s["rid"], s["shape"]
        doc = _short(s["statement"] or s["quote"], 200)
        if s.get("condition"):
            doc += "  [only when: " + _short(s["condition"], 90) + "]"
        nid = _safe(rid + "_" + (s["statement"] or s["quote"])[:28], "n")
        node = None

        if shape == "CONSTRAINT":
            # A prohibition is folded into the slot it governs, never its own node.
            pending_constraints.append(s)
            continue

        if shape == "EMBODIED_KNOWLEDGE":
            # Content is the VERBATIM quote — nothing to generate, so this is
            # complete at skeleton time, not a stub.
            knowledge[_safe(rid, "k")] = {
                "content": s["quote"],
                "traces_to": [rid],
                "resident_on": [last_node["id"]] if last_node is not None else [],
            }
            for art in s["read_artifacts"]:
                tname = _safe("read_" + os.path.basename(art), "t")
                tools.setdefault(tname, dict(_read_tool(art), traces_to=[rid]))
            continue

        if shape == "LIVE_TOOL":
            tname = _safe("consult_" + rid, "t")
            tools[tname] = {
                "surface": "SENSE",
                "sig": "(query) -> str",
                "doc": "Consult the live source at run time (do NOT paraphrase from memory): "
                       + _short(s["quote"], 160),
                "traces_to": [rid],
            }
            tools[tname]["doc"] = _todo(tools[tname]["doc"], "bind the live source call")
            node = {"id": nid, "type": "SENSE", "owner": "code", "tool": tname,
                    "doc": doc, "traces_to": [rid], "writes": [_safe(rid, "s") + "_out"]}
            carries[_safe(rid, "s") + "_out"] = {"type": "str", "produced_by": nid,
                                                 "doc": "live source result"}

        elif shape == "EMBODIED_WRITE":
            tname = _safe("write_" + rid, "t")
            tools[tname] = {
                "surface": "ACT·artifact",
                "sig": "(content, path) -> str",
                "body": "import os\nos.makedirs(os.path.dirname(path) or '.', exist_ok=True)\n"
                        "with open(path, 'w') as f:\n    f.write(content)\nreturn path\n",
                "doc": "Write the deliverable required by " + rid + ": " + _short(s["quote"], 140),
                "traces_to": [rid],
            }
            node = {"id": nid, "type": "ACT", "surface": "artifact", "owner": "code",
                    "tool": tname, "doc": doc, "traces_to": [rid],
                    "writes": [_safe(rid, "a") + "_path"]}
            carries[_safe(rid, "a") + "_path"] = {"type": "str", "produced_by": nid,
                                                  "doc": "written deliverable path"}

        elif shape == "CODE_GATE":
            node = {"id": nid, "type": "ROUTE", "owner": "code",
                    "doc": _todo(doc, "human gate: ask, then branch"), "traces_to": [rid]}

        else:  # NODE (a procedural STEP)
            if s["run_artifacts"]:
                art = s["run_artifacts"][0]
                tname = _safe("run_" + os.path.basename(art), "t")
                tools.setdefault(tname, dict(_run_tool(art), traces_to=[]))
                if rid not in tools[tname]["traces_to"]:
                    tools[tname]["traces_to"].append(rid)
                node = {"id": nid, "type": "ACT", "surface": "artifact", "owner": "code",
                        "tool": tname, "doc": doc, "traces_to": [rid],
                        "writes": [_safe(rid, "r") + "_out"]}
                carries[_safe(rid, "r") + "_out"] = {"type": "str", "produced_by": nid,
                                                     "doc": "script output"}
            elif s["read_artifacts"]:
                art = s["read_artifacts"][0]
                tname = _safe("read_" + os.path.basename(art), "t")
                tools.setdefault(tname, dict(_read_tool(art), traces_to=[]))
                if rid not in tools[tname]["traces_to"]:
                    tools[tname]["traces_to"].append(rid)
                node = {"id": nid, "type": "SENSE", "owner": "code", "tool": tname,
                        "doc": doc, "traces_to": [rid],
                        "writes": [_safe(rid, "d") + "_text"]}
                carries[_safe(rid, "d") + "_text"] = {"type": "str", "produced_by": nid,
                                                      "doc": "bundle file contents"}
            else:
                node = {"id": nid, "type": "GEN-RAW", "owner": "model",
                        "doc": _todo(doc, "write the slot prompt"), "traces_to": [rid],
                        "reads": ["task"], "writes": [_safe(rid, "g") + "_out"]}
                carries[_safe(rid, "g") + "_out"] = {"type": "str", "produced_by": nid,
                                                     "doc": "step output"}
            if s["cohesion"] == "INVOKE_UNIT":
                node["invoke_unit"] = True
                node["doc"] += "  [adaptive unit: keep as ONE tool-using activity]"

        if node is not None:
            _attach_constraints(node)
            nodes.append(node)
            if last_node is not None:
                edges.append({"from": last_node["id"], "to": node["id"]})
            last_node = node

    terminal = {"id": "done", "type": "TERMINAL", "owner": "code",
                "doc": "Report the deliverables.", "traces_to": []}
    _attach_constraints(terminal)          # any trailing prohibitions land here
    nodes.append(terminal)
    if last_node is not None:
        edges.append({"from": last_node["id"], "to": "done"})

    doc = {
        "agir_version": "0.1",
        "standalone": True,
        "shape": "pipeline",
        "skeleton": True,                   # marks a Phase-0 document
        "types": {},
        "knowledge": knowledge,
        "tools": tools,
        "walker": {"name": _safe(name, "w") + "_agent", "carries": carries},
        "nodes": nodes,
        "edges": edges,
    }
    if sub_resources:
        doc["sub_resources"] = list(sub_resources)
    body = yaml.safe_dump(doc, sort_keys=False, width=100, allow_unicode=True)
    return ("---\nname: " + str(name) + "\ndescription: " + _short(description, 180)
            + "\n---\n" + body)
::py::


def artifacts_in(quote: str) -> any {
    # (read, run) bundle artifacts this rule's verbatim span names.
    return _artifacts(quote);
}


def shape_name(r: Rule) -> str {
    # The realization shape this rule REQUIRES, as a plain string.
    sh = required_shape(r.kind, r.modality, r.binds);
    if sh == RealShape.OPTIONAL { return "OPTIONAL"; }
    if sh == RealShape.NODE { return "NODE"; }
    if sh == RealShape.EMBODIED_WRITE { return "EMBODIED_WRITE"; }
    if sh == RealShape.CONSTRAINT { return "CONSTRAINT"; }
    if sh == RealShape.CODE_GATE { return "CODE_GATE"; }
    if sh == RealShape.EMBODIED_KNOWLEDGE { return "EMBODIED_KNOWLEDGE"; }
    if sh == RealShape.LIVE_TOOL { return "LIVE_TOOL"; }
    return "NODE";
}


def stub_specs(spec: RuleSet) -> list {
    # One stub spec per REQUIRED rule, in spec order. OPTIONAL rules (discretionary,
    # non-agent-bound) are carried as nothing — the gate does not demand them.
    out: list = [];
    for r in spec.rules {
        sh = shape_name(r);
        if sh == "OPTIONAL" { continue; }
        coh = "INVOKE_UNIT" if r.cohesion == Cohesion.INVOKE_UNIT else "ATOMIC";
        out.append(_mk_stub(r.id, sh, r.statement, r.quote, r.condition, coh));
    }
    return out;
}


def skeleton_ir(spec: RuleSet, name: str, description: str = "") -> str {
    # Phase 0: the mechanically complete skeleton. Deterministic — no LLM.
    stubs = stub_specs(spec);
    desc = description if description else ("Compiled from the " + str(spec.skill_name) + " skill.");
    return str(emit_yaml(stubs, name, desc, spec.sub_resources));
}


def coverage(spec: RuleSet) -> dict {
    # What the skeleton is obliged to cover, by shape — a compile-time report.
    counts: dict = {};
    required: list = [];
    for r in spec.rules {
        sh = shape_name(r);
        counts[sh] = counts.get(sh, 0) + 1;
        if sh != "OPTIONAL" { required.append(r.id); }
    }
    return {"by_shape": counts, "required_ids": required, "n_required": len(required),
            "n_rules": len(spec.rules)};
}
