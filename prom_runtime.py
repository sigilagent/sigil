"""Prometheus runtime glue — the parts that touch the disk and the OS.

The AG-IR -> OSP *compile* itself lives in Jac (``compiler/compiler.jac``'s
``transpile_ir``); this module only

  1. persists the lowered OSP source to disk as a crystallized module, and
  2. runs a crystallized module in an *isolated subprocess*.

The isolation matters: a compiled OSP agent builds its own task-graph off
``root`` when it runs. If we ran it in-process it would splice its throwaway
task-graph into Prometheus's *persistent* agent graph. A subprocess gives each
execution a fresh, disposable ``root`` — Prometheus keeps only the crystallized
*procedure* (source + AG-IR + stats) on its own graph, never the run artifacts.
"""

import os
import re
import sys
import pathlib
import subprocess

CRYSTAL_DIR = "crystallized"
_HERE = pathlib.Path(os.path.abspath(__file__)).parent


def _jac_bin() -> str:
    """The jac binary that matches THIS interpreter — never a bare `jac` from PATH,
    which may resolve to a different (incompatible) jaclang install."""
    env = os.getenv("PROM_JAC")
    if env:
        return env
    cand = os.path.join(os.path.dirname(sys.executable), "jac")
    return cand if os.path.exists(cand) else "jac"


def repo_root() -> str:
    """Directory that owns this runtime — the Prometheus project root."""
    return str(_HERE)


def default_contract() -> str:
    """The AG-IR authoring contract handed to the frontier crystallizer.

    Prefer the compiler-exact template (a concrete working AG-IR to mimic) over the
    abstract primitive-standard — zero-shot authoring needs the exact schema.
    """
    for name in ("agir-template.md", "agir-standard.md", "agir-primitives.md"):
        p = _HERE / "contracts" / name
        if p.exists():
            return p.read_text()
    return ""


def _slug(s: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "_", (s or "").lower()).strip("_")
    return s[:48] or "task"


def module_name(signature: str, version: int) -> str:
    return f"{_slug(signature)}_v{int(version)}"


def agir_name(text: str) -> str:
    """Best-effort skill signature from an AG-IR: the frontmatter `name:` field, else a slug."""
    for line in (text or "").splitlines():
        s = line.strip()
        if s.startswith("name:"):
            return _slug(s.split(":", 1)[1].strip().strip('"').strip("'"))
        if s and not s.startswith("#") and not s.startswith("---") and ":" not in s:
            break
    return _slug((text or "")[:48])


def install_osp(src_path: str, signature: str, workdir: str = ".") -> str:
    """Drop a precompiled OSP module into crystallized/ and return its new path."""
    d = pathlib.Path(workdir) / CRYSTAL_DIR
    d.mkdir(parents=True, exist_ok=True)
    (d / "__init__.jac").touch(exist_ok=True)
    dst = d / f"{module_name(signature, 1)}.jac"
    dst.write_text(pathlib.Path(src_path).read_text())
    return str(dst)


def write_module(osp_source: str, signature: str, version: int, workdir: str = ".") -> str:
    """Persist a lowered OSP agent as ``crystallized/<sig>_v<n>.jac`` and return its path."""
    d = pathlib.Path(workdir) / CRYSTAL_DIR
    d.mkdir(parents=True, exist_ok=True)
    (d / "__init__.jac").touch(exist_ok=True)  # make it an importable package dir
    mod = module_name(signature, version)
    path = d / f"{mod}.jac"
    path.write_text(osp_source)
    return str(path)


_DRIVER = '''import from crystallized.{mod} {{ run }}
import from byllm.lib {{ Model }}
import prom_observe;
import os;

with entry:__main__ {{
    obs = os.getenv("PROM_OBS", "");
    sig = os.getenv("PROM_SIG", "");
    prom_observe.install(obs, sig);
    model_name = os.getenv("PROM_MODEL", "gpt-4o-mini");
    m = Model(model_name=model_name);
    task = os.getenv("PROM_TASK", "");
    skill = os.getenv("PROM_SKILL", "");
    out = run(task, m, skill);
    print("{marker}");
    print(out);
}}
'''

_MARKER = "<<<PROM_REPORT>>>"

OBS_LOG = "observability/live.jsonl"


def execute_module(module_path: str, task: str, model_name: str,
                   skill: str = "", workdir: str = ".", timeout: int = 1800,
                   mcp_json: str = "", signature: str = "") -> dict:
    """Run a crystallized module in an isolated ``jac run`` subprocess.

    Returns ``{ok, report, error}``. Never raises — a crash/timeout is a typed
    failure the walker escalates (mutate + retry), never a walker abort.
    ``mcp_json`` is the user's registered MCP servers (JSON), exposed to the
    crystallized agent's ``_live_tool`` via ``PROM_MCP``.
    """
    mod = pathlib.Path(module_path).stem
    driver = pathlib.Path(workdir) / f"_driver_{mod}.jac"
    driver.write_text(_DRIVER.format(mod=mod, marker=_MARKER))
    env = dict(os.environ)
    env.update(PROM_MODEL=model_name, PROM_TASK=task, PROM_SKILL=skill)
    env["PROM_OBS"] = str(pathlib.Path(workdir) / OBS_LOG)
    env["PROM_SIG"] = signature
    if mcp_json:
        env["PROM_MCP"] = mcp_json
    jac = _jac_bin()
    try:
        p = subprocess.run([jac, "run", str(driver)], cwd=workdir, env=env,
                           capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return {"ok": False, "report": "", "error": f"timeout after {timeout}s"}
    except FileNotFoundError as ex:
        return {"ok": False, "report": "", "error": f"jac not found: {ex}"}
    finally:
        try:
            driver.unlink()
        except OSError:
            pass
    out = p.stdout or ""
    if _MARKER in out:
        report = out.split(_MARKER, 1)[1].strip()
        ok = p.returncode == 0
    else:
        report = out.strip()
        ok = False
    return {"ok": ok, "report": report, "error": ("" if ok else (p.stderr or "")[-2000:])}
