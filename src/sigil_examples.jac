"""Example skills — the SOURCE `SKILL.md` files you feed the compiler.

Two sources: the tiny starters bundled in the repo (`examples/skills/`), and
community skill packs fetched on demand into `~/.sigil/skills/`. This is distinct
from the compiled `library`: these are the inputs to `sigil compile`, not its
output. Nothing here calls a model — listing and cloning are free.
"""

import os;
import subprocess;

# Known community skill packs, fetched on request (never at install time).
glob _PACKS: dict = {
    "superpowers": "https://github.com/obra/superpowers-skills"
};

def _repo_root() -> str {
    # this module lives in <root>/src/ — bundled examples live in <root>/examples/
    here = os.path.dirname(os.path.abspath(__file__));
    return os.path.dirname(here);
}

def _packs_dir() -> str {
    return os.path.expanduser(os.path.join("~", ".sigil", "skills"));
}

def _pack_names() -> list {
    return [str(k) for k in _PACKS.keys()];
}

def _skill_meta(path: str) -> dict {
    # name + one-line label. Prefer the frontmatter `name:`/`description:`; fall back to
    # the parent folder for the SKILL.md-per-folder convention (obra/superpowers-skills),
    # else the filename. `desc` is the frontmatter description or the first `# heading`.
    desc = ""; fmname = "";
    try {
        with open(path, "r") as f { text = f.read(); }
        for ln in text.split(chr(10))[:24] {
            t = ln.strip();
            if t.lower().startswith("description:") and (not desc) { desc = t.split(":", 1)[1].strip(); }
            elif t.lower().startswith("name:") and (not fmname) { fmname = t.split(":", 1)[1].strip(); }
            elif t.startswith("# ") and (not desc) { desc = t[2:].strip(); }
        }
    } except Exception as e {  }
    base = os.path.basename(path);
    if fmname { name = fmname; }
    elif base.lower() == "skill.md" { name = os.path.basename(os.path.dirname(path)); }
    else { name = base; }
    return {"name": name, "file": base, "path": path, "desc": desc};
}

def _find_skills(base: str) -> list {
    # every *SKILL.md under base (folder-per-skill packs and flat dirs both work)
    out: list = [];
    if not os.path.isdir(base) { return out; }
    for w in os.walk(base) {
        dirpath = w[0]; filenames = w[2];
        for fn in filenames {
            if str(fn).lower().endswith("skill.md") { out.append(os.path.join(dirpath, fn)); }
        }
    }
    out.sort();
    return out;
}

def examples_list() -> dict {
    bundled = [_skill_meta(p) for p in _find_skills(os.path.join(_repo_root(), "examples", "skills"))];
    packs: list = [];
    pd = _packs_dir();
    if os.path.isdir(pd) {
        for entry in sorted(os.listdir(pd)) {
            full = os.path.join(pd, entry);
            if os.path.isdir(full) {
                packs.append({"name": entry, "path": full, "count": len(_find_skills(full))});
            }
        }
    }
    return {"bundled": bundled, "packs": packs, "known_packs": _pack_names()};
}

def examples_fetch(name: str) -> dict {
    key = str(name).strip().lower();
    if key not in _PACKS {
        return {"ok": False, "error": "unknown pack '" + key + "' — known: " + ", ".join(_pack_names())};
    }
    url = str(_PACKS[key]);
    dest = os.path.join(_packs_dir(), key);
    have = os.path.isdir(os.path.join(dest, ".git"));
    try {
        os.makedirs(_packs_dir(), exist_ok=True);
        if have {
            subprocess.run(["git", "-C", dest, "pull", "--ff-only"], check=True, capture_output=True);
            action = "updated";
        } else {
            subprocess.run(["git", "clone", "--depth", "1", url, dest], check=True, capture_output=True);
            action = "cloned";
        }
    } except Exception as e {
        return {"ok": False, "error": "git " + ("pull" if have else "clone") + " failed: " + str(e)[:200]};
    }
    return {"ok": True, "action": action, "name": key, "url": url, "dest": dest, "count": len(_find_skills(dest))};
}
