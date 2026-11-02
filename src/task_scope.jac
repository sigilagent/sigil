"""Task-scoped compilation — `sigil compile <SKILL.md> [--with <SKILL.md>]... --task <task.md>`.

A skill compiles to a program that covers the SKILL's procedure; a task wraps that
procedure in its own inputs, output files and format. Run as a tool inside an agent
loop, the gap between the two is paid in agent turns: the agent reads the program's
report, converts formats, writes the file the task names and re-checks it, and every
such turn re-sends the whole conversation (SkillsBench, glm-5.2: compiled programs
cost 1.5% of the tokens, the turns around them the rest).

Compiling FOR the task closes the gap at compile time: the task's named inputs,
deliverables and format become the program's own IO, and its final step checks
those deliverables. Several skills compose into ONE bundle and ONE program — each
skill's directory is copied under its own subfolder and its file references are
rewritten to point there, so the lift still embodies sibling files and the ejected
program still finds its scripts.

Only the task INSTRUCTION is ever composed in; a verifier or its tests must never be
passed here — that would compile the answer key into the program.
"""

import os;
import re;
import shutil;

glob TASK_PREFACE: str = (
    "Compile the procedures below for EXACTLY this task. The program's inputs are the files "
    + "and values this task names; its deliverables are the output files this task names, in the "
    + "exact location and format it specifies. Its final step must check those deliverables against "
    + "this task's stated requirements and report the result. The skills' own rules still apply."
);

# every relative path a skill bundle holds (files and directories), longest first
# so `scripts/a/b.py` is rewritten before `scripts/a`
def bundle_paths(skill_dir: str) -> list[str] {
    out: list[str] = [];
    if (not skill_dir) or (not os.path.isdir(skill_dir)) { return out; }
    _base: str = str(skill_dir).rstrip("/" + os.sep);
    for (dpath, dirs, fnames) in os.walk(_base) {
        # relative to the bundle root, by prefix (os.walk yields paths under it)
        rd: str = str(dpath)[len(_base):].lstrip("/" + os.sep) or ".";
        if rd != "." {
            if any([str(p).startswith(".") for p in rd.split(os.sep)]) { continue; }
            out.append(rd.replace(os.sep, "/"));
        }
        for fn0 in fnames {
            fn: str = str(fn0);
            if fn.startswith(".") or (rd == "." and fn == "SKILL.md") { continue; }
            out.append(((rd + "/") if rd != "." else "").replace(os.sep, "/") + fn);
        }
    }
    return sorted(out, key=len, reverse=True);
}

# Point every reference to a file the bundle actually holds at `<sub>/<path>`.
# Only paths that EXIST in the bundle are touched, so prose ("run the scripts")
# is never rewritten, and a path already under `<sub>/` is never prefixed twice.
def rewrite_refs(md: str, sub: str, skill_dir: str) -> str {
    text = str(md);
    for rel0 in bundle_paths(skill_dir) {
        rel: str = str(rel0);
        pat: str = r"(?<![\w./-])(\./)?" + str(re.escape(rel)) + r"(?![\w-])";
        # a bare top-level DIRECTORY name ("scripts", "references") is also an
        # ordinary word: rewrite it only when it is written as a path (`scripts/`)
        if ("/" not in rel) and ("." not in rel) { pat = pat + r"(?=/)"; }
        repl: str = (str(sub) + "/" + rel).replace("\\", "\\\\");
        text = str(re.sub(pat, repl, text));
    }
    return text;
}

def _split_frontmatter(md: str) -> list[str] {
    t = str(md);
    if t.startswith("---") {
        parts = t.split("---", 2);
        if len(parts) == 3 { return [str(parts[1]), str(parts[2])]; }
    }
    return ["", t];
}

def _fm_field(fm: str, key: str) -> str {
    m = re.search(r"(?m)^" + re.escape(key) + r"\s*:\s*(.+)$", str(fm));
    return m.group(1).strip().strip("\"'") if m else "";
}

def _slug(s: str) -> str {
    return (re.sub(r"[^a-z0-9]+", "-", str(s).lower()).strip("-") or "task")[:48];
}

# The instruction a task file carries, and nothing else: a SkillsBench task.md
# opens with YAML frontmatter (verifier, sandbox, timeouts) that is harness config,
# not part of the task. Only the body may reach the compiler.
def task_instruction(text: str) -> str {
    return str(_split_frontmatter(str(text))[1]).strip();
}

# Build ONE bundle in out_dir from several skills + the task instruction and return
# the composed SKILL.md path. `task_name` names the composed skill.
def compose_task_skill(skill_paths: list[str], task_text: str, out_dir: str, task_name: str = "") -> str {
    if os.path.isdir(out_dir) { shutil.rmtree(out_dir); }
    os.makedirs(out_dir);
    sections: list[str] = [];
    names: list[str] = [];
    for sp in skill_paths {
        sdir = os.path.dirname(os.path.abspath(str(sp)));
        fm_body: list[str] = _split_frontmatter(str(open(str(sp)).read()));
        nm = _slug(_fm_field(fm_body[0], "name") or os.path.basename(sdir));
        base = nm; k = 2;
        while nm in names { nm = base + "-" + str(k); k += 1; }
        names.append(nm);
        shutil.copytree(sdir, os.path.join(out_dir, nm),
                        ignore=shutil.ignore_patterns(".*", "__pycache__"));
        desc = _fm_field(fm_body[0], "description");
        body = rewrite_refs(str(fm_body[1]).strip(), nm, sdir);
        sections.append("## Skill: " + nm + ("\n\n" + desc if desc else "") + "\n\n" + body);
    }
    tname = _slug(task_name) if task_name else ("task-" + "-".join(names))[:48];
    first = [l.strip() for l in str(task_text).strip().splitlines() if l.strip()];
    tdesc = (first[0] if first else "the target task")[:200].replace("\"", "'");
    md = ("---\nname: " + tname + "\ndescription: \"Complete this task end to end: " + tdesc + "\"\n---\n\n"
          + "## Target task\n\n" + TASK_PREFACE + "\n\n" + str(task_text).strip() + "\n\n"
          + "\n\n".join(sections) + "\n");
    out = os.path.join(out_dir, "SKILL.md");
    with open(out, "w") as fh { fh.write(md); }
    return out;
}
