"""Sigil runtime glue — the parts that touch the disk and the OS.

The AG-IR -> OSP *compile* itself lives in Jac (``compiler/compiler.jac``'s
``transpile_ir``); this module only

  1. persists the lowered OSP source to disk as a compiled module, and
  2. runs a compiled module in an *isolated subprocess*.

The isolation matters: a compiled OSP agent builds its own task-graph off
``root`` when it runs. If we ran it in-process it would splice its throwaway
task-graph into Sigil's *persistent* agent graph. A subprocess gives each
execution a fresh, disposable ``root`` — Sigil keeps only the compiled
*procedure* (source + AG-IR + stats) on its own graph, never the run artifacts.
"""

import os;
import re;
import sys;
import shutil;
import subprocess;
import from pathlib { Path }

glob CRYSTAL_DIR: str = "crystallized";   # legacy dir name — existing installs keep modules here
glob _MARKER: str = "<<<SIGIL_REPORT>>>";
glob OBS_LOG: str = "observability/live.jsonl";

# The driver we write next to each compiled module: it imports the module's
# `run`, binds the small model, installs the token observer, and prints the report
# behind a marker. Kept as a `.format()` template — `{{`/`}}` are literal braces.
glob _DRIVER: str = "import from crystallized.{mod} {{ run }}\n"
    "import from jaclang.byllm.lib {{ Model }}\n"
    "import sigil_observe;\n"
    "import sigil_claude_cc;\n"
    "import os;\n"
    "\n"
    "with entry:__main__ {{\n"
    "    obs = os.getenv(\"SIGIL_OBS\", \"\");\n"
    "    sig = os.getenv(\"SIGIL_SIG\", \"\");\n"
    "    sigil_observe.install(obs, sig);\n"
    "    model_name = os.getenv(\"SIGIL_MODEL\", \"gpt-4o-mini\");\n"
    "    cfg: dict = {{}};\n"
    "    if sigil_claude_cc.is_claude_cc(model_name) {{\n"
    "        sigil_claude_cc.install();\n"
    "        cfg = {{\"native_tools\": False}};\n"
    "    }}\n"
    "    m = Model(model_name=model_name, config=cfg);\n"
    "    task = os.getenv(\"SIGIL_TASK\", \"\");\n"
    "    skill = os.getenv(\"SIGIL_SKILL\", \"\");\n"
    "    out = run(task, m, skill);\n"
    "    print(\"{marker}\");\n"
    "    print(out);\n"
    "}}\n";


# Directory that owns this runtime module (the Sigil project root).
def _here() -> Path {
    return Path(os.path.abspath(__file__)).parent;
}

# The installed native `jac` binary — the self-contained zig bundle that ships its
# own Python + jaclang + byllm runtime (no conda / separate pypi). Resolution:
# `SIGIL_JAC` override; else the `jac` we are already running under (native launch);
# else the `jac` on PATH; else a jac next to this interpreter.
def _jac_bin() -> str {
    env = os.getenv("SIGIL_JAC");
    if env {
        return env;
    }
    exe = sys.executable or "";
    if (os.path.basename(exe) == "jac") and os.path.exists(exe) {
        return exe;
    }
    found = shutil.which("jac");
    if found {
        return found;
    }
    cand = os.path.join(os.path.dirname(exe), "jac");
    return cand if os.path.exists(cand) else "jac";
}

# Directory that owns this runtime — the Sigil project root.
def repo_root() -> str {
    return str(_here());
}

# The project directory (this module lives in `src/`) and its CLI entry point.
# Both are absolute so a subprocess can be spawned from anywhere and still land
# on the same graph — the store is resolved relative to the working directory,
# so `cwd` is not a detail here, it decides which agent you are talking to.
def project_root() -> str {
    return str(_here().parent);
}

def entry_script() -> str {
    return str(_here().parent / "main.jac");
}

# ---------------------------------------------------------------------------
# Process bookkeeping. Anything that runs longer than one command — the cron
# loop today, the full daemon next — leaves a pidfile under `$SIGIL_HOME/run`,
# so a second copy can tell whether the first is still alive and the CLI can
# answer "is anything actually ticking?" without guessing.
# ---------------------------------------------------------------------------
def sigil_home() -> str {
    d = os.getenv("SIGIL_HOME") or os.path.expanduser("~/.sigil");
    try {
        Path(d).mkdir(parents=True, exist_ok=True);
    } except Exception as e {
        return d;
    }
    return d;
}

def run_dir() -> str {
    d = os.path.join(sigil_home(), "run");
    try {
        Path(d).mkdir(parents=True, exist_ok=True);
    } except Exception as e {
        return d;
    }
    return d;
}

def pid_path(name: str) -> str {
    return os.path.join(run_dir(), name + ".pid");
}

def pid_alive(pid: int) -> bool {
    if pid <= 0 {
        return False;
    }
    try {
        os.kill(pid, 0);
    } except ProcessLookupError as e {
        return False;
    } except PermissionError as e {
        return True;      # it exists, it just isn't ours to signal
    } except Exception as e {
        return False;
    }
    return True;
}

def read_pid(name: str) -> int {
    p = Path(pid_path(name));
    if not p.exists() {
        return 0;
    }
    try {
        return int((p.read_text() or "0").strip() or "0");
    } except Exception as e {
        return 0;
    }
}

def clear_pidfile(name: str) -> None {
    p = Path(pid_path(name));
    try {
        if p.exists() {
            p.unlink();
        }
    } except Exception as e {
        return None;
    }
    return None;
}

def write_pidfile(name: str, pid: int = 0) -> str {
    path = pid_path(name);
    try {
        Path(path).write_text(str(pid or os.getpid()));
    } except Exception as e {
        return "";
    }
    return path;
}

def process_running(name: str) -> bool {
    # A pidfile pointing at a dead process is worse than no pidfile — it makes
    # `daemon status` lie. Clear it on the way past.
    pid = read_pid(name);
    if pid <= 0 {
        return False;
    }
    if pid_alive(pid) {
        return True;
    }
    clear_pidfile(name);
    return False;
}

# The AG-IR authoring contract handed to the frontier compiler. Prefer the
# compiler-exact template (a concrete working AG-IR to mimic) over the abstract
# primitive-standard — zero-shot authoring needs the exact schema.
def default_contract() -> str {
    for name in ["agir-template.md", "agir-standard.md", "agir-primitives.md"] {
        p = _here() / "contracts" / name;
        if p.exists() {
            return p.read_text();
        }
    }
    return "";
}

def _slug(s: str) -> str {
    slugged = re.sub(r"[^a-z0-9]+", "_", (s or "").lower()).strip("_");
    return slugged[:48] or "task";
}

def module_name(signature: str, version: int) -> str {
    return f"{_slug(signature)}_v{int(version)}";
}

# Best-effort skill signature from an AG-IR: the frontmatter `name:` field, else a slug.
def agir_name(text: str) -> str {
    for line in (text or "").splitlines() {
        s = line.strip();
        if s.startswith("name:") {
            return _slug(s.split(":", 1)[1].strip().strip('"').strip("'"));
        }
        if s and (not s.startswith("#")) and (not s.startswith("---")) and (":" not in s) {
            break;
        }
    }
    return _slug((text or "")[:48]);
}

# Best-effort human description from a SKILL.md: its frontmatter `description:`.
# A SKILL.md description is written to be a TRIGGER — "use when …" — so it is the
# one string that tells another harness when to reach for the compiled skill.
# Carry it through the compile instead of replacing it with provenance boilerplate
# (see sigil_mcp_serve, where it becomes the MCP tool description).
def skill_description(text: str) -> str {
    lines = (text or "").splitlines();
    started = False;
    for line in lines {
        s = line.strip();
        if not started {
            if not s { continue; }
            if s != "---" { return ""; }   # no frontmatter at all
            started = True;
            continue;
        }
        if s == "---" { break; }           # end of frontmatter
        if s.lower().startswith("description:") {
            return s.split(":", 1)[1].strip().strip('"').strip("'");
        }
    }
    return "";
}

# Drop a precompiled OSP module into crystallized/ and return its new path.
def install_osp(src_path: str, signature: str, workdir: str = ".") -> str {
    d = Path(workdir) / CRYSTAL_DIR;
    d.mkdir(parents=True, exist_ok=True);
    (d / "__init__.jac").touch(exist_ok=True);
    dst = d / f"{module_name(signature, 1)}.jac";
    dst.write_text(Path(src_path).read_text());
    return str(dst);
}

# Persist a lowered OSP agent as ``crystallized/<sig>_v<n>.jac`` and return its path.
def write_module(osp_source: str, signature: str, version: int, workdir: str = ".") -> str {
    d = Path(workdir) / CRYSTAL_DIR;
    d.mkdir(parents=True, exist_ok=True);
    (d / "__init__.jac").touch(exist_ok=True);   # make it an importable package dir
    mod = module_name(signature, version);
    path = d / f"{mod}.jac";
    path.write_text(osp_source);
    return str(path);
}

# Run a compiled module in an isolated ``jac run`` subprocess. Returns
# ``{ok, report, error}``. Never raises — a crash/timeout is a typed failure the
# walker escalates (mutate + retry), never a walker abort. ``mcp_json`` is the
# user's registered MCP servers (JSON), exposed to the run's ``_live_tool`` via
# ``SIGIL_MCP``.
def execute_module(module_path: str, task: str, model_name: str,
                   skill: str = "", workdir: str = ".", timeout: int = 1800,
                   mcp_json: str = "", signature: str = "") -> dict {
    mod = Path(module_path).stem;
    driver = Path(workdir) / f"_driver_{mod}.jac";
    driver.write_text(_DRIVER.format(mod=mod, marker=_MARKER));
    env = dict(os.environ);
    env.update(SIGIL_MODEL=model_name, SIGIL_TASK=task, SIGIL_SKILL=skill);
    env["SIGIL_OBS"] = str(Path(workdir) / OBS_LOG);
    env["SIGIL_SIG"] = signature;
    if mcp_json {
        env["SIGIL_MCP"] = mcp_json;
    }
    jacbin = _jac_bin();
    try {
        p = subprocess.run([jacbin, "run", str(driver)], cwd=workdir, env=env,
                           capture_output=True, text=True, timeout=timeout);
    } except subprocess.TimeoutExpired as e {
        return {"ok": False, "report": "", "error": f"timeout after {timeout}s"};
    } except FileNotFoundError as ex {
        return {"ok": False, "report": "", "error": f"jac not found: {ex}"};
    } finally {
        if driver.exists() {
            driver.unlink();
        }
    }
    out = p.stdout or "";
    if _MARKER in out {
        rep = out.split(_MARKER, 1)[1].strip();
        # a clean exit with an empty or INCOMPLETE report is a silent failure —
        # the superpowers sweep's escape-hatch runs exited 0 with empty hands.
        ok = (p.returncode == 0) and bool(rep) and (not rep.startswith("INCOMPLETE"));
    } else {
        rep = out.strip();
        ok = False;
    }
    return {"ok": ok, "report": rep, "error": ("" if ok else (p.stderr or "")[-2000:])};
}
