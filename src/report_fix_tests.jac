"""Regression tests for the compiled-run report convention.

The bug: `_exec_script` discarded the authored script's stdout and returned the
script path, so a run's report was a filename (e.g. `op.py`) instead of the answer —
every skill silently scored 0 on grounded eval. These lock in the fix: stdout is
captured, `_artifact_text` surfaces text CONTENT, and binary artifacts stay as paths.
Run with `jac test report_fix_tests.jac`.
"""

::py::
import os, sys, subprocess as _subprocess, tempfile

def _asset_checks():
    here = os.path.dirname(os.path.abspath(__file__))
    src = open(os.path.join(here, "compiler", "mechanical", "assets", "osp_runtime.py.txt")).read()
    ns = {"os": os, "sys": sys, "_subprocess": _subprocess}
    exec(src, ns)
    exec_script = ns["_exec_script"]
    artifact_text = ns["_artifact_text"]
    cwd = os.getcwd()
    d = tempfile.mkdtemp()
    os.chdir(d)
    try:
        # a print-based script (the case that used to be dropped)
        path = exec_script("print('alice@acme.io, bob@globex.com, team@initech.co')")
        stdout_text = artifact_text(path)
        # a plain string is passed through untouched
        passthrough = artifact_text("plain string, not a path")
        # a binary artifact is summarised, never dumped as bytes
        with open("chart.png", "wb") as f:
            f.write(b"\x89PNG\r\n" + b"\x00" * 40)
        binref = artifact_text("chart.png")
    finally:
        os.chdir(cwd)
    return {"stdout_text": stdout_text, "passthrough": passthrough, "binref": binref}

def _tui_checks():
    import io, os, sys
    here = os.path.dirname(os.path.abspath(__file__))
    src = open(os.path.join(here, "compiler", "mechanical", "assets", "osp_runtime.py.txt")).read()
    ns = {"os": os, "sys": sys, "_subprocess": _subprocess}
    exec(src, ns)
    out = {}
    os.environ["AGIR_TUI"] = "1"
    os.environ.pop("AGIR_PROGRESS", None)
    buf = io.StringIO()
    old_stdout = sys.stdout
    sys.stdout = buf
    try:
        ns["_tui_banner"]("csv-extractor", "extract the tables")
        ns["_progress"]("parse")
        ns["_progress"]("emit")
        ns["_tui_finish"]("csv-extractor done | artifact=out.csv", ["out.csv"])
    finally:
        sys.stdout = old_stdout
    out["on"] = buf.getvalue()
    os.environ["AGIR_TUI"] = "0"
    ns["_TUI"]["last"] = None
    buf2 = io.StringIO()
    sys.stdout = buf2
    try:
        ns["_progress"]("parse")
        ns["_tui_finish"]("x", [])
    finally:
        sys.stdout = old_stdout
    out["off"] = buf2.getvalue()
    os.environ["AGIR_TUI"] = "1"
    ns["__builtins__"]["input"] = lambda *_: "blue, please"
    buf3 = io.StringIO()
    sys.stdout = buf3
    try:
        out["hil_answer"] = ns["_ask_user"]("Which color?")
    finally:
        sys.stdout = old_stdout
    out["hil_prompt"] = buf3.getvalue()
    os.environ["AGIR_TUI"] = "0"
    return out

::py::

test "run report surfaces printed CONTENT, not the script path" {
    r = _asset_checks();
    assert "alice@acme.io" in r["stdout_text"], f"got: {r['stdout_text']}";
    assert "bob@globex.com" in r["stdout_text"];
    assert "team@initech.co" in r["stdout_text"];
    assert "op.py" not in r["stdout_text"];
}

test "artifact_text passes non-paths through and keeps binaries as a path ref" {
    r = _asset_checks();
    assert r["passthrough"] == "plain string, not a path";
    assert "chart.png" in r["binref"];
    assert "bytes" in r["binref"];
}

test "artifact TUI: forced-on renders banner, node path, and outcome" {
    r = _tui_checks();
    assert "csv-extractor" in r["on"];
    assert "parse" in r["on"] and "emit" in r["on"];
    assert "out.csv" in r["on"];
    assert chr(27) in r["on"];   # ANSI styling present
}

test "artifact TUI: forced-off keeps the batch contract byte-silent" {
    r = _tui_checks();
    assert r["off"] == "";
}

test "artifact TUI: a terminal asks HIL questions inline" {
    r = _tui_checks();
    assert r["hil_answer"] == "blue, please";
    assert "Which color?" in r["hil_prompt"];
}
