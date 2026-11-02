"""Tests — task-scoped compilation (compose several skills + a task into ONE bundle)."""

import tempfile;

def _mk(base_dir: str, rel: str, text: str) -> None {
    p = os.path.join(base_dir, rel);
    os.makedirs(os.path.dirname(p), exist_ok=True);
    with open(p, "w") as fh { fh.write(text); }
}

def _two_skills() -> list[any] {
    base_dir = str(tempfile.mkdtemp());
    _mk(base_dir, "a/SKILL.md", "---\nname: alpha\ndescription: Alpha does A.\n---\n# Alpha\nRun `scripts/run.py`, or ./scripts/run.py, then read FORMS.md.\nKeep the scripts folder tidy; see scripts/ for helpers.\n");
    _mk(base_dir, "a/scripts/run.py", "print('a')\n");
    _mk(base_dir, "a/FORMS.md", "forms\n");
    _mk(base_dir, "b/SKILL.md", "---\nname: beta\ndescription: Beta does B.\n---\n# Beta\nSee [the guide](references/guide.md).\n");
    _mk(base_dir, "b/references/guide.md", "guide\n");
    return [base_dir, os.path.join(base_dir, "a", "SKILL.md"), os.path.join(base_dir, "b", "SKILL.md")];
}

test "a task and several skills compose into one bundle with the task first" {
    fx = _two_skills();
    out = os.path.join(fx[0], "bundle");
    task = "Compute the total and write it to /root/answer.txt, rounded to 2 decimals.";
    path = compose_task_skill([fx[1], fx[2]], task, out);
    md = open(path).read();
    assert md.startswith("---\nname: task-alpha-beta\n");
    assert "## Target task" in md;
    assert TASK_PREFACE in md;
    assert task in md;
    # the task comes before the skills it is compiled against
    assert md.index("## Target task") < md.index("## Skill: alpha") < md.index("## Skill: beta");
    # each skill's own files travel with it, under its own subfolder
    assert os.path.isfile(os.path.join(out, "alpha", "scripts", "run.py"));
    assert os.path.isfile(os.path.join(out, "alpha", "FORMS.md"));
    assert os.path.isfile(os.path.join(out, "beta", "references", "guide.md"));
}

test "file references point into the skill's subfolder; prose is untouched" {
    fx = _two_skills();
    md = open(compose_task_skill([fx[1], fx[2]], "Do the task.", os.path.join(fx[0], "bundle"))).read();
    assert "`alpha/scripts/run.py`" in md;
    assert "or alpha/scripts/run.py," in md;          # a ./ prefix is normalised too
    assert "read alpha/FORMS.md." in md;
    assert "see alpha/scripts/ for helpers" in md;     # a directory written as a path
    assert "Keep the scripts folder tidy" in md;       # the same word as prose is not
    assert "(beta/references/guide.md)" in md;
    assert "alpha/alpha/" not in md;
    assert "beta/beta/" not in md;
}

test "two skills with the same name get distinct subfolders" {
    fx = _two_skills();
    out = os.path.join(fx[0], "bundle");
    md = open(compose_task_skill([fx[1], fx[1]], "Do it.", out)).read();
    assert "## Skill: alpha\n" in md;
    assert "## Skill: alpha-2\n" in md;
    assert os.path.isdir(os.path.join(out, "alpha-2", "scripts"));
}

test "only a task file's instruction is composed, never its frontmatter" {
    txt = "---\nverifier:\n  type: test-script\nagent:\n  timeout_sec: 900\n---\n\nCompute X and write /root/answer.txt.\n";
    assert task_instruction(txt) == "Compute X and write /root/answer.txt.";
    assert task_instruction("Plain instruction.") == "Plain instruction.";
}
