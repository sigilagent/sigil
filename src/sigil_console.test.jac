# Tests for sigil_console — annex of sigil_console.jac (`jac test sigil_console.jac`).
# The compile-job plumbing behind the console's Compile page: paths that must not
# leave the job folder, the question/answer handshake, and job state. SIGIL_HOME
# points at a temp dir, and nothing here starts a compile or calls a model.

import os;
import json;
import tempfile;

def _home -> str | None {
    prev = os.environ.get("SIGIL_HOME");
    os.environ["SIGIL_HOME"] = tempfile.mkdtemp();
    return prev;
}

def _unhome(prev: str | None) {
    if prev is None { os.environ.pop("SIGIL_HOME", None); } else { os.environ["SIGIL_HOME"] = prev; }
}

def _fake_job(job: str, files: dict[str, any]) -> str {
    d = _job_dir(job);
    os.makedirs(d, exist_ok=True);
    for (name, data) in files.items() {
        with open(os.path.join(d, name), "w") as f { f.write(json.dumps(data)); }
    }
    return d;
}

test "uploaded paths stay inside the skill folder" {
    assert _clean_rel("refs/api.md") == "refs/api.md";
    assert _clean_rel("/abs/SKILL.md") == "abs/SKILL.md";
    assert _clean_rel("./SKILL.md") == "SKILL.md";
    assert _clean_rel("win\\style\\path.md") == "win/style/path.md";
    assert _clean_rel("../etc/passwd") == "";
    assert _clean_rel("a/../../b") == "";
    assert _clean_rel("") == "";
}

test "a job id is ours or it is refused" {
    assert _job_ok("1760000000000-a1b2c3");
    assert not _job_ok("");
    assert not _job_ok("../escape");
    assert not _job_ok("a/b");
    assert not _job_ok("x" * 65);
}

test "the skill's name comes from its frontmatter, else its folder" {
    md = "---" + chr(10) + "name: \"pdf-tables\"" + chr(10) + "description: d" + chr(10) + "---" + chr(10) + "# Body";
    assert _skill_name(md, "folder") == "pdf-tables";
    assert _skill_name("# No frontmatter" + chr(10) + "name: not-this", "folder") == "folder";
    assert _skill_name("---" + chr(10) + "description: only" + chr(10) + "---", "folder") == "folder";
}

test "an upload without a SKILL.md is refused and leaves nothing behind" {
    prev = _home();
    r = compile_start([{"path": "notes/readme.md", "text": "# hi"}], "ask");
    assert (not r["ok"]) and ("SKILL.md" in str(r["error"])), str(r);
    assert os.listdir(_jobs_root()) == [], os.listdir(_jobs_root());
    r2 = compile_start([], "ask", "/no/such/folder/anywhere");
    assert (not r2["ok"]) and ("no folder" in str(r2["error"])), str(r2);
    _unhome(prev);
}

test "the first question (number 0) can be answered" {
    # `.get("i") or -1` once turned question 0 into -1, so the first unclear
    # rule of every "Ask me" compile could never be answered.
    prev = _home();
    job = "1760000000000-abc123";
    d = _fake_job(job, {"job.json": {"job": job, "name": "t", "mode": "ask"},
                        "ask.json": {"i": 0, "question": "Q?"}});
    r = compile_answer(job, 0, "Do");
    assert r["ok"] and (r["answer"] == "do"), str(r);
    with open(os.path.join(d, "answer.json")) as f { got = json.loads(f.read()); }
    assert _qnum(got) == 0;
    assert not compile_answer(job, 1, "do")["ok"], "question 1 was never asked";
    assert not compile_answer(job, 0, "perhaps")["ok"];
    assert not compile_answer("../" + job, 0, "do")["ok"];
    _unhome(prev);
}

test "a job's state reads from its files" {
    prev = _home();
    done = "1760000000001-done01";
    _fake_job(done, {"job.json": {"job": done, "name": "t", "mode": "decide"},
                     "result.json": {"ok": True, "status": "compiled", "signature": "t_sig", "version": 1}});
    st = compile_status(done);
    assert st["ok"] and (st["state"] == "done"), str(st);
    gone = "1760000000002-gone01";
    _fake_job(gone, {"job.json": {"job": gone, "name": "t", "mode": "decide"}});
    assert compile_status(gone)["state"] == "stopped", "no pid and no result: the child is gone";
    assert not compile_status("nope-0")["ok"];
    rows = compile_jobs();
    assert [r["job"] for r in rows] == [gone, done], str(rows);
    assert rows[1]["signature"] == "t_sig";
    _unhome(prev);
}
