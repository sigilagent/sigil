"""AI compiler — the gate battery. This module seeds it with G4, the compile
oracle: round-trip a candidate AG-IR through the MECHANICAL half
(transpile_ir) and the jac type-checker. This is the property a manual lift
never has — a deterministic ground truth on every iteration. Later gates
(standalone / C1 / determinization / STRUCT-COV / grounding) land beside it.

Every verdict is typed and must be ROUTED by the caller — an unrouted failure
is a silent success (pipeline B.9.1).
"""

import os;
import re;
import shutil;
import subprocess;
import tempfile;
import traceback;
# absolute import (main.jac style): a parent-relative `..mechanical` breaks under
# `jac test`, which roots the package at the module's own directory.
import from src.compiler.mechanical.compiler { transpile_ir }
import from .lift_types { CompileVerdict }

def _jac_bin() -> str {
    env = os.environ.get("SIGIL_JAC", "");
    if env and os.path.isfile(env) { return env; }
    w = shutil.which("jac");
    if w { return str(w); }
    home = os.path.expanduser("~/.local/bin/jac");
    if os.path.isfile(home) { return home; }
    return "jac";
}

def compile_gate(ir_text: str, name: str, check: bool = True) -> CompileVerdict {
    # G4: the AG-IR must lower mechanically and type-check with zero errors.
    osp = "";
    try {
        osp = str(transpile_ir(ir_text, name));
    } except Exception as e {
        return CompileVerdict(ok=False, errors="transpile failed: " + str(traceback.format_exc())[-1200:]);
    }
    if "def run(" not in osp {
        return CompileVerdict(ok=False, module_src=osp, errors="lowered module has no run() entrypoint");
    }
    # The mechanical half is permissive: unparseable/empty IR still lowers to a
    # bare module whose run() returns "". That is a SILENT SUCCESS — fail loud
    # instead (the same choice sigil's _lower makes): require ≥1 lowered node.
    if "can n_" not in osp {
        return CompileVerdict(ok=False, module_src=osp, errors="lowered module has no nodes (empty/unparseable IR)");
    }
    if not check { return CompileVerdict(ok=True, module_src=osp); }
    tmp = tempfile.mkdtemp(prefix="sigil_g4_");
    path = os.path.join(tmp, re.sub(r"[^0-9a-zA-Z_]", "_", str(name)) + ".jac");
    try {
        with open(path, "w") as f { f.write(osp); }
        r = subprocess.run([_jac_bin(), "check", path], capture_output=True, text=True, timeout=180);
        out = str(r.stdout) + "\n" + str(r.stderr);
        n_err = len(re.findall(r"error\[E\d+\]", out));
        if (n_err > 0) or ("FAILED" in out and "PASSED" not in out) {
            tail = out[-1600:];
            return CompileVerdict(ok=False, module_src=osp, errors=f"jac check: {n_err} error(s)\n{tail}");
        }
        return CompileVerdict(ok=True, module_src=osp);
    } except Exception as e {
        return CompileVerdict(ok=False, module_src=osp, errors="jac check could not run: " + str(e)[:400]);
    } finally {
        try { shutil.rmtree(tmp); } except Exception {  }
    }
}
