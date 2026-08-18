"""Replay existing AG-IRs through raise2's canonicalize rung and report what it did.

Re-compiling a skill to measure a compiler change is a poor experiment: the
author is a model, so two runs of the SAME compiler produce different IRs and the
change you are measuring is buried in that variance. Replaying a fixed corpus of
already-authored IRs removes the model from the loop entirely — the only thing
that varies is the phase.

For each IR it reports whether the document parsed as strict YAML before and
after, whether the lowered module is byte-identical, and whether the rung fired. Identical modules are the property the phase rests on: a refinement may
change the IR's form and must not change what it lowers to.

    jac run tools/replay-canonicalize.jac            # REPLAY_DIR=<dir of */agent.agir>

Point REPLAY_DIR at any directory of compiled skills — `sigil compile -e out/x/agent.jac`
writes `out/x/agent.agir` beside each artifact.
"""
import from src.compiler.ai.autofix { canonicalize_ir }
import from src.compiler.ai.spec_loop { RuleSet }
import from src.compiler.ai.gates { compile_gate }
import from src.sigil_agir_yaml { strict_parses }
import os;
import glob;
import hashlib;

def _sha(s: any) -> str {
    return hashlib.sha256(str(s).encode()).hexdigest()[:12];
}

with entry:__main__ {
    base_dir = os.environ.get("REPLAY_DIR", "");
    paths = sorted(glob.glob(os.path.join(base_dir, "*", "agent.agir")));
    n_mal = 0; n_fixed = 0; n_same = 0; n_diff = 0; n_tot = 0;
    print("skill                strict  ->  strict   module-identical   lines");
    for p in paths {
        skill = os.path.basename(os.path.dirname(p));
        with open(p) as f { txt = f.read(); }
        n_tot += 1;
        s0 = strict_parses(txt);
        if not s0 { n_mal += 1; }
        cand = str(canonicalize_ir(txt, skill + "_replay"));
        new_ir = cand if cand else txt;
        s1 = strict_parses(new_ir);
        a = compile_gate(txt, skill + "_ra", False);
        b = compile_gate(new_ir, skill + "_rb", False);
        ident = (_sha(a.module_src) == _sha(b.module_src)) and a.ok and b.ok;
        if (["canonicalize"] if cand else []) {
            if s1 { n_fixed += 1; }
            if ident { n_same += 1; } else { n_diff += 1; }
        }
        print((skill + "                    ")[:20]
              + ("  " + str(s0) + "   ->  " + str(s1) + "   ")
              + ("   " + str(ident) + "            ")[:18]
              + str(len(txt.splitlines())) + " -> " + str(len(new_ir.splitlines()))
              + ("   canonicalized" if (["canonicalize"] if cand else []) else "   (no-op)"));
    }
    print("");
    print("IRs replayed:            " + str(n_tot));
    print("malformed (needed relax):" + str(n_mal) + "/" + str(n_tot));
    print("canonicalized to strict: " + str(n_fixed) + "/" + str(n_mal));
    print("module byte-identical:   " + str(n_same) + "/" + str(n_same + n_diff));
}
