# Tests for toolib — annex (loads with `toolib.jac`, which `compiler.jac` imports).
#
# A tool body is emitted as a SELF-CONTAINED function body, and every failure
# inside it is caught by the body's own `try` and returned as a string. That
# makes an undefined name invisible: `run_command` shipped for a while returning
# "[run_command failed: name '_shutil' is not defined]" on every single call,
# with `jac check` clean and the whole suite green, because nothing ever ran one.
# These tests run one.

import ast;
import shutil;

::py::
import os as _os


def _rt_text():
    here = _os.path.dirname(_os.path.abspath(__file__))
    return open(_os.path.join(here, "assets", "osp_runtime.py.txt")).read()
::py::


def _call_builtin(name: str, args: dict[str, any]) -> str {
    # Build the tool the way the lowering does — the canonical sig's parameters
    # as the function's parameters, the registered body as its body — and call
    # it. No compiler involvement, so a failure here is the BODY's.
    b = builtin(name);
    assert b is not None, "no such builtin: " + name;
    body = str(b["body"]);
    params = str(b["sig"]).split("->")[0].strip().strip("()");
    pnames = [p.split(":")[0].strip() for p in params.split(",") if p.strip()];
    src = "def _tool(" + ", ".join(pnames) + "):\n";
    for ln in body.splitlines() { src += ("    " + ln + "\n") if ln.strip() else "\n"; }
    ast.parse(src);                       # the body is valid Python on its own
    ns: dict[str, any] = {};
    exec(compile(src, "<toolib:" + name + ">", "exec"), ns);
    return str(ns["_tool"](**args));
}

test "run_command actually runs — a missing import is not swallowed as a failure string" {
    out = _call_builtin("run_command", {"command": "echo hi"});
    assert "run_command failed" not in out, out;      # the NameError shape
    assert "is not defined" not in out, out;
    assert "exit=0" in out, out;
    assert "hi" in out, out;
}

test "run_command runs BASH, so bash syntax is not a syntax error" {
    # The live failure this guards: /bin/sh is dash on Debian/Ubuntu, a model
    # drafts bash, and dash dies on the first "(" with
    #   /bin/sh: 2: Syntax error: "(" unexpected
    # An array literal is that exact shape, and is a no-op under bash.
    if shutil.which("bash") is None { return; }       # no bash: nothing to assert
    out = _call_builtin("run_command", {"command": "arr=(a b c); echo ${arr[1]}"});
    assert "exit=0" in out, out;
    assert "b" in out, out;
    assert "Syntax error" not in out, out;
}

test "every builtin body parses, and declares the names it uses" {
    # Each body is emitted standalone, so it must import its own stdlib. This is
    # the check that would have caught `_shutil`: a name that is loaded, never
    # bound in the body, and not a parameter or a builtin.
    import builtins;
    bad: list[any] = [];
    for n in builtin_names() {
        b = builtin(n);
        params = str(b["sig"]).split("->")[0].strip().strip("()");
        bound = {p.split(":")[0].strip() for p in params.split(",") if p.strip()};
        tree = ast.parse(str(b["body"]));
        for node in ast.walk(tree) {
            if isinstance(node, ast.Import) or isinstance(node, ast.ImportFrom) {
                for a in node.names { bound.add((a.asname or a.name).split(".")[0]); }
            } elif isinstance(node, ast.Name) and isinstance(node.ctx, ast.Store) {
                bound.add(node.id);
            } elif isinstance(node, ast.ExceptHandler) and node.name {
                bound.add(str(node.name));
            }
        }
        for node in ast.walk(tree) {
            if isinstance(node, ast.Name) and isinstance(node.ctx, ast.Load) {
                if (node.id not in bound) and (not hasattr(builtins, node.id)) {
                    bad.append(n + ": " + node.id);
                }
            }
        }
    }
    assert bad == [], "tool body uses a name it never imports or binds: " + str(bad);
}

test "write_file refuses to write non-JSON into a .json deliverable" {
    # The output-name fallback reads the filename out of the task, so a skill
    # that produces a Markdown report writes it to the report.json the task
    # named. energy-ac did exactly that: all 24 checks died on JSONDecodeError
    # at char 0, and the agent found the deliverable already present.
    import os;
    import tempfile;
    d = tempfile.mkdtemp(prefix="sigil_wf_");
    fn = builtin("write_file");
    assert fn, "write_file is not a builtin";

    src = str(fn.get("body"));
    for needle in ["_ext == \".json\"", "write_file refused", "_json.loads"] {
        assert needle in src, "write_file lost its format guard: " + needle;
    }
    # the guard must not touch a path with no format claim, nor real JSON
    assert ".md" in src, "the refused content must still be preserved somewhere";
    # the same guard lives in the runtime's _write_artifact (GEN-RAW deliverables)
    rt = _rt_text();
    assert "def _extract_json" in rt and "def _refuse_json_write" in rt and "def _format_contract" in rt, "runtime lost the JSON recovery/refusal helpers";
}

test "write_file recovers a fenced or prose-wrapped JSON document, refuses pure Markdown" {
    import os;
    import json;
    import tempfile;
    d = tempfile.mkdtemp(prefix="sigil_wfj_");
    out = _call_builtin("write_file", {"path": d + "/a.json", "content": "```json\n{\"mass_kg\": 2.5}\n```"});
    assert "refused" not in out, out;
    assert json.load(open(d + "/a.json"))["mass_kg"] == 2.5;
    out = _call_builtin("write_file", {"path": d + "/b.json", "content": "Here is the report:\n[{\"id\": 1}]\nDone."});
    assert "refused" not in out, out;
    assert json.load(open(d + "/b.json"))[0]["id"] == 1;
    out = _call_builtin("write_file", {"path": d + "/c.json", "content": "# Report\n\nNothing structured here."});
    assert "write_file refused" in out, out;
    assert "produce it yourself" in out, out;
    assert not os.path.exists(d + "/c.json");
    assert os.path.exists(d + "/c.md");
}

test "write_file never creates or overwrites a file with empty content" {
    import os;
    import tempfile;
    d = tempfile.mkdtemp(prefix="sigil_wfe_");
    open(d + "/answer.json", "w").write("{\"keep\": 1}");
    out = _call_builtin("write_file", {"path": d + "/answer.json", "content": "   "});
    assert "skipped" in out and "empty content" in out, out;
    assert open(d + "/answer.json").read() == "{\"keep\": 1}", "existing deliverable was clobbered";
    out2 = _call_builtin("write_file", {"path": d + "/new.txt", "content": ""});
    assert not os.path.exists(d + "/new.txt"), "empty write created a file";
}

test "write_file refuses a report written to a .csv deliverable, recovers a fenced csv block, passes rows" {
    import os;
    import tempfile;
    d = tempfile.mkdtemp(prefix="sigil_wfc_");
    out = _call_builtin("write_file", {"path": d + "/results.csv", "content": "# Matched Filter Report\n\nNo triggers above threshold."});
    assert "write_file refused" in out and "CSV rows" in out, out;
    assert not os.path.exists(d + "/results.csv") and os.path.exists(d + "/results.md");
    out2 = _call_builtin("write_file", {"path": d + "/r2.csv", "content": "Here are the rows:\n```csv\nid,snr\n1,9.2\n```\n"});
    assert "refused" not in out2, out2;
    assert open(d + "/r2.csv").read().startswith("id,snr"), open(d + "/r2.csv").read();
    out3 = _call_builtin("write_file", {"path": d + "/r3.csv", "content": "id,snr\n1,9.2\n"});
    assert "refused" not in out3 and open(d + "/r3.csv").read() == "id,snr\n1,9.2\n";
}

test "write_file never overwrites a registered INPUT and never puts text into a binary-format path" {
    import os;
    import tempfile;
    d = tempfile.mkdtemp(prefix="sigil_wfb_");
    open(d + "/book.xlsx", "wb").write(b"PK\x03\x04real-workbook-bytes");
    out = _call_builtin("write_file", {"path": d + "/book.xlsx", "content": "import pandas as pd\nprint(1)\n"});
    assert "write_file refused" in out and "binary document format" in out, out;
    assert open(d + "/book.xlsx", "rb").read().startswith(b"PK"), "the workbook was overwritten";
    assert os.path.exists(d + "/book.xlsx.txt");
}

test "SIGIL_WRITE_GUARDS=0 writes verbatim, in write_file and in the runtime writer" {
    # the escape hatch for a task the guards are wrong about: Markdown into a
    # .json path is refused by default and written as-is once the flag is off
    import os;
    import tempfile;
    d = tempfile.mkdtemp(prefix="sigil_wg_");
    p = os.path.join(d, "report.json");
    r = _call_builtin("write_file", {"path": p, "content": "# not json"});
    assert "refused" in str(r), str(r);
    assert not os.path.exists(p);
    os.environ["SIGIL_WRITE_GUARDS"] = "0";
    try {
        r2 = _call_builtin("write_file", {"path": p, "content": "# not json"});
    } finally {
        del os.environ["SIGIL_WRITE_GUARDS"];
    }
    assert str(r2) == p, str(r2);
    assert open(p).read() == "# not json";
    rt = _rt_text();
    assert "_sigil_on(\"WRITE_GUARDS\")" in rt and "_sigil_on(\"INPUT_CAPS\")" in rt, "runtime lost its opt-out switches";
}
