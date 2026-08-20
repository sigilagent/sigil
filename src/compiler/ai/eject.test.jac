"""Tests — eject. The module source comes from a LIVE transpile of a toy IR;
the ejected single-file program must itself pass `jac check` clean."""

import re;
import shutil;
import subprocess;
import tempfile;
import from .gates { compile_gate }

glob TOY_IR: str = """---
name: note-writer
description: Write a short note to a file.
---
agir_version: 0.1
standalone: true
shape: pipeline
types: {}
walker:
  name: NoteAgent
  carries:
    task:
      type: str
      role: input
    note:
      type: str
      produced_by: draft
nodes:
  - id: draft
    type: GEN-RAW
    owner: model
    reads: [task]
    writes: [note]
    doc: "Write the note the task asks for."
  - id: done
    type: TERMINAL
edges:
  - {from: draft, to: done, modality: mandatory}
""";

test "eject wraps a compiled module into a shebang'd runnable with a CLI shim" {
    v = compile_gate(TOY_IR, "note_writer_ej", check=False);
    assert v.ok;
    prog = eject_program(v.module_src, "note-writer");
    lines = prog.splitlines();
    assert lines[0] == "#!/usr/bin/env -S jac run";
    assert "with entry:__main__ {" in prog;
    assert "def run(" in prog;                       # the module rode along intact
    assert "SIGIL_MODEL" in prog;
    assert prog.count("#!") == 1;
}

test "the ejected program parses direct args and carries the MCP server" {
    v = compile_gate(TOY_IR, "note_writer_ej_mcp", check=False);
    prog = eject_program(v.module_src, "note-writer");
    assert "def _mcp_serve(" in prog;                              # self-hosted tool server rides along
    assert "_mcp_serve(run, Model, _ej_keys, \"note-writer\"" in prog;
    assert "\"--mcp\" in [str(a) for a in _ej_raw]" in prog;      # serve-mode entry branch
    assert "_ej_params[" in prog;                                  # --key=value binds walker inputs
    assert "params=_ej_params" in prog;                            # ...and reaches run()
}

test "the ejected program itself passes jac check, and lands executable" {
    v = compile_gate(TOY_IR, "note_writer_ej2", check=False);
    prog = eject_program(v.module_src, "note-writer");
    d = tempfile.mkdtemp(prefix="sigil_eject_");
    try {
        path = write_program(prog, os.path.join(d, "note_writer.jac"));
        assert (os.stat(path).st_mode & 0o111) != 0;   # executable bit set
        jac = os.environ.get("SIGIL_JAC", "") or shutil.which("jac") or os.path.expanduser("~/.local/bin/jac");
        r = subprocess.run([str(jac), "check", path], capture_output=True, text=True, timeout=180);
        out = str(r.stdout) + str(r.stderr);
        assert len(re.findall(r"error\[E\d+\]", out)) == 0, out[-800:];
    } finally {
        shutil.rmtree(d, ignore_errors=True);
    }
}

test "the ejected artifact ships the skill's other files as an escape hatch" {
    # Bundling embodies what it can; the rest must still be reachable at run
    # time, or an artifact that looks up forms.md finds nothing and guesses.
    sk = tempfile.mkdtemp(prefix="sigil_sc_skill_");
    out = tempfile.mkdtemp(prefix="sigil_sc_out_");
    os.makedirs(os.path.join(sk, "scripts"));
    with open(os.path.join(sk, "SKILL.md"), "w") as f { f.write("# PDF\nfill it\n"); }
    with open(os.path.join(sk, "forms.md"), "w") as f { f.write("field_id rules\n"); }
    with open(os.path.join(sk, "scripts", "fill.py"), "w") as f { f.write("def fill(): pass\n"); }
    with open(os.path.join(sk, "blank.pdf"), "w") as f { f.write("%PDF-1.4\n"); }

    ep = os.path.join(out, "pdf.jac");
    with open(ep, "w") as f { f.write("# artifact\n"); }
    copied = copy_skill_sidecars(sk, ep);

    # the reference doc, the script, and the binary payload all travel
    assert "forms.md" in copied;
    assert os.path.join("scripts", "fill.py") in copied;
    assert "blank.pdf" in copied;
    assert os.path.isfile(os.path.join(out, "forms.md"));
    assert os.path.isfile(os.path.join(out, "scripts", "fill.py"));
    # SKILL.md is the compiled source, not a run-time input
    assert "SKILL.md" not in copied;
    # the artifact itself is never overwritten by the copy
    assert open(ep).read() == "# artifact\n";
}

test "sidecar copying never fails a compile" {
    # best-effort by contract: a missing or unreadable skill dir must not raise
    out = tempfile.mkdtemp(prefix="sigil_sc_out_");
    ep = os.path.join(out, "x.jac");
    with open(ep, "w") as f { f.write("# artifact\n"); }
    assert copy_skill_sidecars("", ep) == [];
    assert copy_skill_sidecars(os.path.join(out, "does-not-exist"), ep) == [];
}
