"""Regression tests for the crystallized-run report convention.

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
    src = open(os.path.join(here, "compiler", "assets", "osp_runtime.py.txt")).read()
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
