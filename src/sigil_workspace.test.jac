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
    assert ws_read("notes/a.txt") == "hello";
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
    assert ws_read("f.txt") == "one 2 three";
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
