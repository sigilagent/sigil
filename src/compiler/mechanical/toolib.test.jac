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

def _call_builtin(name: str, args: dict) -> str {
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
    ns: dict = {};
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
    bad: list = [];
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
