# Tests for sigil_workspace — annex of sigil_workspace.jac (`jac test sigil_workspace.jac`).
# Exercises path resolution, the exec-approval gate, never-killed shell jobs, the
# in-process `sigil compile` route, and the SSRF guard. No model.

import os;
import tempfile;
import from .sigil { configure }
import from .approvals { allowlist_add, approvals_set }

test "paths: relative resolves in the workspace, absolute reaches the real host" {
    d = tempfile.mkdtemp();
    configure("workspace", d);
    configure("sandbox", "off");          # the default
    assert "wrote" in ws_write("notes/a.txt", "hello");
    assert "hello" in ws_read("notes/a.txt");
    # no jail: an absolute path outside the workspace is a normal, allowed read
    out = ws_read("/etc/hosts");
    assert "escapes" not in out, out[:120];
    # and a write outside the workspace lands where it was asked to
    outside = os.path.join(tempfile.mkdtemp(), "beyond.txt");
    assert "wrote" in ws_write(outside, "x");
    assert os.path.exists(outside);
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

test "sandbox on: the workspace is a jail again; off is the default" {
    d = tempfile.mkdtemp();
    configure("workspace", d);
    configure("sandbox", "jail");
    assert "wrote" in ws_write("inside.txt", "ok");        # inside is unaffected
    # relative and absolute escapes are both refused, and nothing lands outside
    assert "escapes" in ws_write("../evil.txt", "x");
    assert "escapes" in ws_read("/etc/hosts");
    assert not os.path.exists(os.path.join(os.path.dirname(d), "evil.txt"));
    # an unknown mode is rejected, leaving the setting as it was
    assert "must be one of" in configure("sandbox", "banana");
    assert "escapes" in ws_read("/etc/hosts");
    # back off -> the same absolute read is fine again
    configure("sandbox", "off");
    assert "escapes" not in ws_read("/etc/hosts");
}

test "exec: non-allowlisted command is gated, allowlisted runs in the workspace" {
    d = tempfile.mkdtemp();
    configure("workspace", d);
    configure("sandbox", "off");
    approvals_set("allowlist", "on-miss");
    # not allowlisted + no approver wired in tests -> blocked, never runs
    blocked = ws_exec("madeupcmd --danger");
    assert ("BLOCKED" in blocked) or ("approval" in blocked) or ("DENIED" in blocked), blocked;
    # allowlist a safe command -> it runs, starting in the workspace
    allowlist_add("echo");
    out = ws_exec("echo hello-shell");
    assert "exit=0" in out and "hello-shell" in out, out;
}

test "exec: a slow command is reported, NOT killed — ws_watch sees it through" {
    configure("workspace", tempfile.mkdtemp());
    configure("sandbox", "off");
    approvals_set("full", "off");
    # wait_seconds elapses long before the command does: it must come back as
    # STILL RUNNING with a job id, and the process must survive that report.
    out = ws_exec("echo starting; sleep 3; echo finished", 1);
    assert "STILL RUNNING" in out, out;
    assert "starting" in out, out;            # the output SO FAR is handed over
    assert "finished" not in out, out;        # ...and only that
    jid = out.split("[job ")[1].split("]")[0];
    # keep watching -> the same job finishes on its own, nothing was interrupted
    more = ws_watch(jid, 10);
    assert "exit=0" in more, more;
    assert "finished" in more, more;          # new output since the last look
    assert "starting" not in more, more;      # already reported, not repeated
}

test "exec: ws_kill stops a job, ws_jobs lists it" {
    configure("workspace", tempfile.mkdtemp());
    configure("sandbox", "off");
    approvals_set("full", "off");
    out = ws_exec("sleep 30", 1);
    assert "STILL RUNNING" in out, out;
    jid = out.split("[job ")[1].split("]")[0];
    assert jid in ws_jobs(), ws_jobs();
    assert "stopped job" in ws_kill(jid), ws_kill(jid);
    assert "already finished" in ws_kill(jid);
}

test "exec: `sigil compile` is routed in-process, never shelled out" {
    configure("workspace", tempfile.mkdtemp());
    configure("sandbox", "off");
    approvals_set("full", "off");
    # the in-process compiler answers for a missing file; a shelled-out `sigil`
    # would have produced a job report (or a not-found exit) instead.
    out = ws_exec("sigil compile /nope/missing-skill.md");
    assert "no such file" in out, out;
    assert "[job " not in out, out;
    # same answer through the tool the agent is supposed to call directly
    assert "no such file" in sigil_compile("/nope/missing-skill.md");
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
