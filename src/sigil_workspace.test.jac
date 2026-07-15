# Tests for sigil_workspace — annex of sigil_workspace.jac (`jac test sigil_workspace.jac`).
# Exercises the sandbox jail, the exec-approval gate, and the SSRF guard. No model.

import os;
import tempfile;
import from .sigil { configure }
import from .approvals { allowlist_add, approvals_set }

test "path jail: writes land inside, escapes are refused" {
    d = tempfile.mkdtemp();
    configure("workspace", d);
    assert "wrote" in ws_write("notes/a.txt", "hello");
    assert "hello" in ws_read("notes/a.txt");
    # relative and absolute escapes both refused
    assert "escapes" in ws_write("../evil.txt", "x");
    assert "escapes" in ws_read("/etc/passwd");
    # the escaping write did NOT create a file outside the jail
    assert not os.path.exists(os.path.join(os.path.dirname(d), "evil.txt"));
}

test "edit: unique replace only" {
    d = tempfile.mkdtemp();
    configure("workspace", d);
    ws_write("f.txt", "one two three");
    assert "edited" in ws_edit("f.txt", "two", "2");
    assert "one 2 three" in ws_read("f.txt");
    # non-unique target is refused
    ws_write("g.txt", "a a a");
    assert "not unique" in ws_edit("g.txt", "a", "b");
}

test "ssrf guard: blocks loopback/private/link-local, allows public" {
    assert _ssrf_ok("https://example.com/path");
    assert _ssrf_ok("http://93.184.216.34/");
    assert not _ssrf_ok("http://localhost:8080");
    assert not _ssrf_ok("http://127.0.0.1");
    assert not _ssrf_ok("http://169.254.169.254/latest/meta-data");
    assert not _ssrf_ok("http://192.168.1.1");
    assert not _ssrf_ok("http://10.0.0.5");
    assert not _ssrf_ok("http://172.16.5.5");
    assert not _ssrf_ok("file:///etc/passwd");
}

test "exec: sandbox off disables shell" {
    configure("sandbox_mode", "off");
    assert "disabled" in ws_exec("echo hi");
}

test "exec: non-allowlisted command is gated, allowlisted runs in the jail" {
    d = tempfile.mkdtemp();
    configure("workspace", d);
    configure("sandbox_mode", "jail");
    approvals_set("allowlist", "on-miss");
    # not allowlisted + no approver wired in tests -> blocked, never runs
    blocked = ws_exec("madeupcmd --danger");
    assert ("BLOCKED" in blocked) or ("approval" in blocked) or ("DENIED" in blocked), blocked;
    # allowlist a safe command -> it runs, cwd-confined to the workspace
    allowlist_add("echo");
    out = ws_exec("echo hello-jail");
    assert "exit=0" in out and "hello-jail" in out, out;
}

test "ws_read: paging with offset/limit + position header" {
    d = tempfile.mkdtemp();
    configure("workspace", d);
    body = "";
    for i in range(1, 51) { body += "line-" + str(i) + chr(10); }
    ws_write("big.txt", body);
    # first page: header shows position, and there's a continue hint
    p1 = ws_read("big.txt", 0, 10);
    assert "of 51" in p1, p1[:80];          # 50 lines + trailing empty split
    assert "line-1" in p1 and "line-10" in p1;
    assert "line-11" not in p1;             # page stopped at 10
    assert "more line" in p1;               # continue hint
    # a later page: offset jumps in, numbering reflects real line
    p2 = ws_read("big.txt", 20, 5);
    assert "line-20" in p2 and "line-24" in p2;
    assert "line-19" not in p2 and "line-25" not in p2;
}

test "ws_tree: recursive survey, skips noise dirs" {
    d = tempfile.mkdtemp();
    configure("workspace", d);
    ws_write("src/app/main.py", "x=1");
    ws_write("src/util.py", "y=2");
    ws_write("node_modules/pkg/index.js", "z=3");   # should be pruned
    t = ws_tree(".", 3);
    assert "src" in t and "main.py" in t and "util.py" in t, t;
    assert "node_modules" not in t, "noise dir not pruned:\n" + t;
}

test "ws_grep: finds matches with path:line, or reports none" {
    d = tempfile.mkdtemp();
    configure("workspace", d);
    ws_write("a.py", "import os" + chr(10) + "def foo():" + chr(10) + "    return 42");
    ws_write("b.txt", "nothing here");
    g = ws_grep("def foo", ".");
    assert "a.py:2:" in g, g;
    assert "no matches" in ws_grep("zzz_not_present", ".");
    # scoping to a single file works too
    assert "a.py:1:" in ws_grep("import", "a.py");
}
