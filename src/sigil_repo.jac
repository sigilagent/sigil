"""Compile a whole skills repo — give a repo link (or a local dir), and Sigil
clones it, reads it to say what it is and how to install it, discovers its
SKILL.md files, and lets you pick which to compile.

Scope: skills-LIBRARY repos — a repo whose content IS skill files (e.g.
obra/superpowers-skills). Discovery is deterministic (walk for *SKILL.md);
the "what is this / how do I install it" brief is one focused model pass over
the README. Compilation reuses the same gated compiler as `sigil compile <file>`.
"""

import os;
import subprocess;
import from jaclang.byllm.lib { Model }
import from .sigil { bind_chat_model, compile_skill }
import from .sigil_examples { _find_skills, _skill_meta, _packs_dir }

glob repo_llm: any = Model(model_name="gpt-4o-mini");

def _ensure_repo_llm() -> None {
    # rebind the brief model from the graph (chat/frontier tier) — same pattern as sub-agents
    repo_llm = bind_chat_model();
}

def _slug(link: str) -> str {
    s = str(link).strip().rstrip("/");
    if s.endswith(".git") { s = s[:-4]; }
    return s.split("/")[-1] if "/" in s else s;
}

def stem(name: str) -> str {
    n = str(name);
    for suf in [".SKILL.md", ".skill.md", ".md"] {
        if n.lower().endswith(suf.lower()) { return n[:len(n) - len(suf)]; }
    }
    return n;
}

def looks_like_repo(arg: str) -> bool {
    # a directory, a git URL, or a bare owner/repo — anything but a single skill file
    a = str(arg).strip();
    if not a { return False; }
    if os.path.isdir(a) { return True; }
    if a.startswith("http://") or a.startswith("https://") or a.startswith("git@") or a.endswith(".git") { return True; }
    if ("/" in a) and (" " not in a) and (not os.path.exists(a)) and (not a.lower().endswith(".md")) {
        parts = a.split("/");
        if (len(parts) == 2) and parts[0] and parts[1] { return True; }   # owner/repo
    }
    return False;
}

def resolve_repo(link: str) -> dict {
    # local dir -> use in place; URL / owner-repo -> clone (or update) into ~/.sigil/skills/<name>
    a = str(link).strip();
    if os.path.isdir(a) {
        full = os.path.abspath(a);
        return {"ok": True, "path": full, "name": os.path.basename(full), "cloned": False, "url": ""};
    }
    url = a if (a.startswith("http") or a.startswith("git@")) else ("https://github.com/" + a.rstrip("/"));
    name = _slug(url);
    dest = os.path.join(_packs_dir(), name);
    have = os.path.isdir(os.path.join(dest, ".git"));
    try {
        os.makedirs(_packs_dir(), exist_ok=True);
        if have {
            subprocess.run(["git", "-C", dest, "pull", "--ff-only"], check=True, capture_output=True);
        } else {
            subprocess.run(["git", "clone", "--depth", "1", url, dest], check=True, capture_output=True);
        }
    } except Exception as e {
        return {"ok": False, "error": "git " + ("pull" if have else "clone") + " failed: " + str(e)[:200], "url": url, "path": dest, "name": name};
    }
    return {"ok": True, "path": dest, "name": name, "url": url, "cloned": True};
}

def repo_skills(path: str) -> list {
    return [_skill_meta(p) for p in _find_skills(path)];
}

def _read_readme(path: str) -> str {
    for nm in ["README.md", "readme.md", "README", "README.rst", "INSTALL.md", "INSTALL"] {
        p = os.path.join(path, nm);
        if os.path.isfile(p) {
            try { with open(p, "r") as f { return f.read(); } }
            except Exception as e {  }
        }
    }
    return "";
}

obj RepoBrief {
    has summary: str;          # one line: what this repo is
    has install: list[str];    # exact shell commands to install/set it up (empty if none)
}

sem repo_brief = """Read a skills-repository README and state, in ONE line, what the repo is.
Then extract the EXACT shell commands a user must run to install or set it up so its skills can
run. Return an empty install list if nothing needs installing. Do NOT invent commands — only
what the README actually prescribes, verbatim.""";
sem repo_brief.readme = "The repository README / INSTALL text.";
def repo_brief(readme: str) -> RepoBrief by repo_llm();

def understand_repo(path: str) -> dict {
    # one focused model pass: what is this repo + how to install it (from its README)
    readme = _read_readme(path);
    if not readme { return {"summary": "", "install": []}; }
    _ensure_repo_llm();
    try {
        b = repo_brief(readme[:6000]);
        return {"summary": str(b.summary), "install": [str(x) for x in list(b.install)]};
    } except Exception as e {
        return {"summary": "", "install": [], "error": str(e)[:160]};
    }
}

def install_run(path: str, cmds: list) -> list {
    # run each install command in the repo dir; return a per-command result
    out: list = [];
    for c in cmds {
        try {
            r = subprocess.run(str(c), shell=True, cwd=path, capture_output=True, text=True, timeout=600);
            out.append({"cmd": str(c), "ok": (r.returncode == 0), "output": (str(r.stdout) + str(r.stderr))[-400:]});
        } except Exception as e {
            out.append({"cmd": str(c), "ok": False, "output": str(e)[:200]});
        }
    }
    return out;
}

def compile_one(meta: dict, eject: bool) -> dict {
    # compile a single discovered skill file; auto-named eject (one path can't serve many)
    try { src = open(str(meta["path"])).read(); }
    except Exception as e { return {"name": meta["name"], "ok": False, "error": "read failed: " + str(e)[:120]}; }
    r = compile_skill(src, eject, "", None);
    return {
        "name": str(meta["name"]), "ok": bool(r["ok"]), "signature": str(r["signature"]),
        "module": str(r["module"]), "eject": str(r["eject"]), "issues": [str(x) for x in list(r["issues"] or [])]
    };
}

def repo_compile_batch(link: str, which: list, eject: bool) -> dict {
    # non-interactive path: clone, discover, compile the selection (or all), report.
    rr = resolve_repo(link);
    if not rr["ok"] { return {"ok": False, "error": str(rr["error"])}; }
    sk = repo_skills(rr["path"]);
    want = [str(w) for w in which];
    sel = sk if not want else [s for s in sk if (str(s["name"]) in want) or (stem(str(s["name"])) in want)];
    results = [compile_one(s, eject) for s in sel];
    return {"ok": True, "path": rr["path"], "name": rr["name"], "cloned": bool(rr["cloned"]),
            "skills": sk, "selected": len(sel), "results": results};
}
