"""Sigil runtime glue — the parts that touch the disk and the OS.

The AG-IR -> OSP *compile* itself lives in Jac (``compiler/compiler.jac``'s
``transpile_ir``); this module only

  1. persists the lowered OSP source to disk as a crystallized module, and
  2. runs a crystallized module in an *isolated subprocess*.

The isolation matters: a compiled OSP agent builds its own task-graph off
``root`` when it runs. If we ran it in-process it would splice its throwaway
task-graph into Sigil's *persistent* agent graph. A subprocess gives each
execution a fresh, disposable ``root`` — Sigil keeps only the crystallized
*procedure* (source + AG-IR + stats) on its own graph, never the run artifacts.
"""

import os;
import re;
import sys;
import shutil;
import subprocess;
import from pathlib { Path }

glob CRYSTAL_DIR: str = "crystallized";
glob _MARKER: str = "<<<SIGIL_REPORT>>>";
glob OBS_LOG: str = "observability/live.jsonl";

# The driver we write next to each crystallized module: it imports the module's
# `run`, binds the small model, installs the token observer, and prints the report
# behind a marker. Kept as a `.format()` template — `{{`/`}}` are literal braces.
glob _DRIVER: str = "import from crystallized.{mod} {{ run }}\n"
    "import from jaclang.byllm.lib {{ Model }}\n"
    "import sigil_observe;\n"
    "import os;\n"
    "\n"
    "with entry:__main__ {{\n"
    "    obs = os.getenv(\"SIGIL_OBS\", \"\");\n"
    "    sig = os.getenv(\"SIGIL_SIG\", \"\");\n"
    "    sigil_observe.install(obs, sig);\n"
    "    model_name = os.getenv(\"SIGIL_MODEL\", \"gpt-4o-mini\");\n"
    "    m = Model(model_name=model_name);\n"
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

# The AG-IR authoring contract handed to the frontier crystallizer. Prefer the
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

# Run a crystallized module in an isolated ``jac run`` subprocess. Returns
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
