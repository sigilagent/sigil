"""AI compiler — eject: package a compiled OSP module as ONE runnable program.

The mechanical half already injects the full runtime helper library verbatim
into every generated module, so the module is self-contained — ejecting is
appending a CLI entry shim (argv -> task, model from env, print the report)
plus a `jac run` shebang, and marking the file executable:

    sigil compile SKILL.md -e agent.jac
    ./agent.jac "extract the tables from report.pdf"     # SIGIL_MODEL=... to pick the model

The AG-IR stays on the graph (TaskGraph.agir) — compile-time provenance never
rides the runnable (and never enters a prompt).
"""

import os;

def eject_program(module_src: str, name: str) -> str {
    # `#` opens a comment in jac, so the shebang line is legal source; `env -S`
    # splits the argument so `./prog.jac task` execs `jac run ./prog.jac task`.
    header = (
        "#!/usr/bin/env -S jac run\n"
        + "# " + name + " — standalone agent ejected by the sigil AI compiler.\n"
        + "# Usage: ./" + name + ".jac \"<task>\"   (or: jac run " + name + ".jac -- \"<task>\")\n"
        + "# Model: $SIGIL_MODEL, else $SIGIL_SMALL, else gpt-4o-mini.\n\n"
    );
    shim = (
        "\n\nwith entry:__main__ {\n"
        + "    import sys;\n"
        + "    import os;\n"
        + "    # accept both `./prog.jac task...` and `jac run prog.jac -- task...`\n"
        + "    _ej_raw = sys.argv;\n"
        + "    _ej_args = _ej_raw[_ej_raw.index(\"--\") + 1:] if \"--\" in _ej_raw else _ej_raw[1:];\n"
        + "    _ej_args = [str(a) for a in _ej_args if not str(a).startswith(\"-\")];\n"
        + "    if not _ej_args {\n"
        + "        print(\"usage: " + name + ".jac \\\"<task>\\\"\");\n"
        + "    } else {\n"
        + "        _ej_task = \" \".join(_ej_args);\n"
        + "        _ej_name = os.environ.get(\"SIGIL_MODEL\", os.environ.get(\"SIGIL_SMALL\", \"gpt-4o-mini\"));\n"
        + "        print(run(_ej_task, Model(model_name=_ej_name), \"\"));\n"
        + "    }\n"
        + "}\n"
    );
    return header + module_src.rstrip() + shim;
}

def write_program(text: str, path: str) -> str {
    d = os.path.dirname(path);
    if d { os.makedirs(d, exist_ok=True); }
    with open(path, "w") as f { f.write(text); }
    os.chmod(path, 0o755);
    return path;
}
