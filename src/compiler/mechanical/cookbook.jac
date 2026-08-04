"""The golden AG-IR cookbook — location + validation.

docs/reference/agir-cookbook/*.agir is a curated library of hand-reviewed golden
AG-IRs. This module resolves the directory and validates every file through the
compile oracle (G4) + type unification (G9), so both the test annex and any CLI
check share one implementation."""

import os;
import glob;
import from src.compiler.ai.gates { compile_gate, gate_type_unification }

def cookbook_dir() -> str {
    # this module: src/compiler/mechanical/ -> repo root is three up
    here = os.path.dirname(os.path.abspath(__file__));
    base = os.path.abspath(os.path.join(here, "..", "..", ".."));
    return os.path.join(base, "docs", "reference", "agir-cookbook");
}

def cookbook_files() -> list {
    d = cookbook_dir();
    files = sorted(glob.glob(os.path.join(d, "*.agir")));
    # a *.FAILED.agir is an inspection artifact, never a golden
    return [f for f in files if not f.endswith(".FAILED.agir")];
}

# [{name, ok, errors, g9}] for every golden AG-IR — a clean one has ok=True, g9=[].
def validate_cookbook() -> list {
    out: list = [];
    for f in cookbook_files() {
        name = os.path.splitext(os.path.basename(f))[0];
        ir = "";
        with open(f) as fh { ir = fh.read(); }
        v = compile_gate(ir, name);
        g9 = [str(x) for x in gate_type_unification(ir)] if v.ok else [];
        out.append({"name": name, "ok": bool(v.ok),
                    "errors": str(v.errors)[:800], "g9": g9});
    }
    return out;
}
