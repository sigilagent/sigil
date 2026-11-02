"""envbind — the SkillRT Pass-2 analog: manifest extraction, install-time
probe, preflight emission. Pure code, no model."""

def _ir_with_tools(tools: dict[str, any]) -> dict[str, any] {
    return {"tools": tools, "nodes": [], "edges": []};
}

test "a tool body reading process IO is flagged; param-reading bodies are not" {
    ir = _ir_with_tools({
        "hooky": {"body": "import json, sys\ndata = json.load(sys.stdin)\nreturn data.get('user_input')", "sig": "() -> str"},
        "arger": {"body": "import sys\npath = sys.argv[1]\nreturn open(path).read()", "sig": "() -> str"},
        "clean": {"body": "return (text or '').upper()", "sig": "(text: str) -> str"},
        # `input` as a variable/param name is NOT the builtin prompt call
        "named": {"body": "return input_path or ''", "sig": "(input_path: str) -> str"}
    });
    m = extract_manifest(ir);
    pio = m["proc_io"];
    assert "hooky" in pio;
    assert "arger" in pio;
    assert "clean" not in pio;
    assert "named" not in pio;
}

test "python imports are extracted and mapped to pip names" {
    ir = _ir_with_tools({
        "render": {"body": "import fitz\nfrom PIL import Image\nreturn out", "sig": "(out) -> path"},
        "frames": {"body": "from core.gif_builder import GIFBuilder\nreturn 1"}
    });
    m = extract_manifest(ir);
    assert "fitz" in m["py"];
    assert m["py"]["fitz"]["pip"] == "pymupdf";
    assert "PIL" in m["py"];
    assert m["py"]["PIL"]["pip"] == "pillow";
    # the slack-gif-creator class: a skill-local module is a dependency too
    assert "core" in m["py"];
    assert "frames" in m["py"]["core"]["tools"];
}

test "stdlib and runtime-provided imports never enter the manifest" {
    ir = _ir_with_tools({
        "t": {"body": "import os, json\nimport re\nfrom jaclang.byllm.lib import Model\nreturn 1"}
    });
    m = extract_manifest(ir);
    assert manifest_empty(m);
}

test "command binaries are extracted; heredocs, flags and noise are not" {
    ir = _ir_with_tools({
        "convert": {"command": "pandoc in.md -o out.docx\n--flag-continuation value\ncat <<EOF\nmodule.exports = {}\nconst x = 1\nEOF\nmkdir -p out"},
        "shellish": {"body": "qpdf --decrypt in.pdf out.pdf"}
    });
    m = extract_manifest(ir);
    assert "pandoc" in m["bin"];
    assert "qpdf" in m["bin"];
    assert "module.exports" not in m["bin"];
    assert "const" not in m["bin"];
    assert "mkdir" not in m["bin"];
    assert "--flag-continuation" not in m["bin"];
}

test "probe flags what this runtime cannot import or find" {
    ir = _ir_with_tools({
        "t": {"body": "import zz_definitely_not_a_module_9x\nreturn 1"},
        "c": {"command": "zz-definitely-not-a-cli-9x --version"}
    });
    pr = probe_manifest(extract_manifest(ir));
    assert len(pr["missing_py"]) == 1;
    assert pr["missing_py"][0][0] == "zz_definitely_not_a_module_9x";
    assert len(pr["missing_bin"]) == 1;
    assert pr["missing_bin"][0][0] == "zz-definitely-not-a-cli-9x";
}

test "probe passes what this runtime has" {
    ir = _ir_with_tools({"t": {"body": "import yaml\nreturn 1"}});
    pr = probe_manifest(extract_manifest(ir));
    assert not pr["missing_py"];
}

test "preflight source embeds the manifest and the probe function" {
    ir = _ir_with_tools({"t": {"body": "import fitz\nreturn 1"}});
    src = preflight_src(extract_manifest(ir));
    assert "_ENV_MANIFEST" in src;
    assert "def _env_preflight" in src;
    assert "pymupdf" in src;
    assert "SIGIL_ENV_AUTOBIND" in src;
    # empty manifest -> no block at all (the module stays untouched)
    assert preflight_src({"py": {}, "bin": {}}) == "";
}

test "preflight binds closure-visibly: artifact-local target, closure pip, honest message" {
    # the #149 contract: a missing module is remediated into a dir the CLOSURE
    # interpreter imports from, installed by the closure's own pip — and the
    # residual failure message names the probed interpreter with a working command
    ir = _ir_with_tools({"t": {"body": "import docx\nreturn 1"}});
    src = preflight_src(extract_manifest(ir));
    # installs land beside the module and rejoin sys.path each run
    assert "pydeps" in src;
    assert "--target" in src;
    assert "_sys.path.insert" in src;
    assert "invalidate_caches" in src;
    # the installer is _sys.executable (`jac -m pip` = the closure's pip);
    # `which python3` is the interpreter the closure never sees
    assert '_sp.run([_sys.executable, "-m", "pip"' in src;
    assert 'which("python3")' not in src;
    # bind is default-on (mutates only the artifact); =0 opts out
    assert '"SIGIL_ENV_AUTOBIND", ""' in src and '!= "0"' in src;
    # the failure note is copy-pasteable remediation, not the pip dead end
    assert "probed %s" in src;
    assert "python-docx" in src;
}

test "a fabricated input path and an unguarded external read are both flagged" {
    # verbatim shape of the live fault: brand-guidelines made 0 model calls in
    # all 27 cells across 3 models because find_deck_path fell back to a
    # literal and inspect_deck opened it with no guard, so the walker died
    # before its first slot and the skill scored a legitimate-looking 0.
    ir = _ir_with_tools({
        "find_deck_path": {
            "sig": "(task) -> path",
            "body": "import re\nm = re.search(r'([\\w.-]+\\.pptx)', task)\nreturn m.group(1) if m else \"presentation.pptx\""
        },
        "inspect_deck": {
            "sig": "(deck_path) -> str",
            "body": "prs = Presentation(deck_path)\nreturn str(len(prs.slides))"
        }
    });
    m = extract_manifest(ir);
    assert "find_deck_path" in m["fabricated_path"];
    assert m["fabricated_path"]["find_deck_path"] == "presentation.pptx";
    assert "inspect_deck" in m["unguarded_read"];
}

test "well-formed IO tools are not flagged" {
    # negative control: a sentinel-returning resolver, an exists-guarded read,
    # a try-wrapped read, and a read of a literal the tool just wrote.
    ir = _ir_with_tools({
        "resolve_input": {
            "sig": "(task) -> path",
            "body": "import re\nm = re.search(r'([\\w.-]+\\.docx)', task)\nreturn m.group(1) if m else \"\""
        },
        "read_guarded": {
            "sig": "(p) -> str",
            "body": "import os\nif not os.path.exists(p):\n    return ''\nreturn open(p).read()"
        },
        "read_try": {
            "sig": "(p) -> str",
            "body": "try:\n    return open(p).read()\nexcept FileNotFoundError:\n    return ''"
        },
        "write_then_read": {
            "sig": "(text) -> path",
            "body": "open(\"out.html\", \"w\").write(text)\nreturn \"out.html\""
        }
    });
    m = extract_manifest(ir);
    assert m["fabricated_path"] == {};
    assert m["unguarded_read"] == {};
}

test "the offer-letter shape: paths mined from the task, opened through an expression" {
    # verbatim shape of the live fault (offer-letter-generator, every cell 0 while
    # MCP delivery worked): the SENSE tool recovers its files by regex over the task
    # sentence, so the caller cannot name them and the phrasing decides which file
    # is opened — a run whose sentence named only the OUTPUT opened the output as
    # its template. The read that died is `Document(spec.get("template_path"))`, an
    # EXPRESSION argument, which the bare-name matcher never saw.
    ir = _ir_with_tools({
        "load_template_data": {
            "sig": "(task) -> dict",
            "body": ("import re, json, os\n"
                     "text = task or \"\"\n"
                     "docxs = re.findall(r'[^\\s]+\\.docx\\b', text)\n"
                     "jsons = re.findall(r'[^\\s]+\\.json\\b', text)\n"
                     "template_path = docxs[0] if docxs else \"template.docx\"\n"
                     "output_path = docxs[1] if len(docxs) > 1 else \"output.docx\"\n"
                     "data_path = jsons[0] if jsons else \"data.json\"\n"
                     "return {\"template_path\": template_path}")
        },
        "scan_placeholders": {
            "sig": "(template_spec) -> dict",
            "body": "from docx import Document\ndoc = Document(spec.get(\"template_path\"))\nreturn {}"
        }
    });
    m = extract_manifest(ir);
    # the mined names are input provenance, reported per tool
    mined = m["task_scraped_paths"]["load_template_data"];
    assert "template_path" in mined;
    assert "data_path" in mined;
    assert "output_path" in mined;
    # the invented literal is a defect wherever it is assigned — the tool's own
    # name and signature say nothing about paths
    assert "load_template_data" in m["fabricated_path"];
    # and the expression-argument read is now seen
    assert "scan_placeholders" in m["unguarded_read"];
}

test "well-formed IO tools stay clean under the widened matchers" {
    # negative control for the widening: a guarded read, a try-wrapped read, a
    # literal the tool just wrote, and a resolver with an EMPTY sentinel fallback.
    ir = _ir_with_tools({
        "read_guarded": {"sig": "(p) -> str",
            "body": "import os\nif not os.path.exists(p):\n    return ''\nreturn open(p).read()"},
        "read_try": {"sig": "(p) -> str",
            "body": "try:\n    return open(p).read()\nexcept FileNotFoundError:\n    return ''"},
        "write_then_read": {"sig": "(text) -> path",
            "body": "open(\"out.html\", \"w\").write(text)\nreturn \"out.html\""},
        "resolve_input": {"sig": "(task) -> path",
            "body": "import re\nm = re.search(r'([\\w.-]+\\.docx)', task)\nreturn m.group(1) if m else \"\""}
    });
    m = extract_manifest(ir);
    assert m["unguarded_read"] == {};
    assert m["fabricated_path"] == {};
    # a resolver that RETURNS its find (no pathish assignment) is not a mined input
    assert m["task_scraped_paths"] == {};
}

test "path_ext_hint recovers the file type a derived path was guessing at" {
    # The lift states the type twice — in the scrape pattern and in the literal
    # fallback — and lifting the name to an input threw both away, leaving the
    # caller a bare name to match on (energy-ac fed `network_path` a .md
    # write-up with network.json beside it, 32 calls, 0 passes).
    body = "import re\nm = re.search(r'([\\w.-]+\\.json)', task)\n"
           + "network_path = m.group(1) if m else \"network.json\"\nreturn network_path";
    assert path_ext_hint(body, "network_path") == [".json"];

    # an alternation names every type it accepts
    body2 = "import re\nsheet_file = re.search(r'\\.(xlsx|csv)', task)";
    got2 = path_ext_hint(body2, "sheet_file");
    assert ".xlsx" in got2 and ".csv" in got2, str(got2);

    # a body that never names a type says nothing rather than guessing
    assert path_ext_hint("return task.strip()", "some_path") == [];
    assert path_ext_hint("", "some_path") == [];
}

test "path_ext_hint reads the type off the OPENER when no filename is present" {
    # The commonest shape by far: a tool that takes `path` as a parameter has no
    # filename literal in it at all. That left power-flow-data advertising
    # `network_path` and `size_path` with byte-identical descriptions, and the
    # agent handed the solver the file it had meant to measure.
    load_json = "def load_network(path: str) -> dict:\n    import json\n"
                + "    with open(path) as f:\n        data = json.load(f)\n    return data";
    assert path_ext_hint(load_json, "path") == [".json"];

    sizer = "def check_file_size(path: str) -> str:\n    import os\n"
            + "    return str(os.path.getsize(path))";
    assert path_ext_hint(sizer, "path") == [], "a generic file probe must claim no type";

    assert path_ext_hint("wb = load_workbook(path)", "path") == [".xlsx"];
    assert path_ext_hint("doc = Document(path)", "path") == [".docx"];
    assert path_ext_hint("r = PdfReader(path)", "path") == [".pdf"];

    # a literal still wins over the opener: it is the more specific evidence
    both = "p = \"deck.pptx\"\nprs = Presentation(p)";
    assert path_ext_hint(both, "p") == [".pptx"];
}

test "a tool that shells out to sys.executable is detected" {
    ir = _ir_with_tools({
        "spawns": {"sig": "(p) -> str",
            "body": "import subprocess, sys\nproc = subprocess.run([sys.executable, \"s.py\", p], capture_output=True)\nreturn proc.stdout"},
        "spawns_alias": {"sig": "(p) -> str",
            "body": "import subprocess as _sp, sys as _sys\nreturn _sp.run([_sys.executable, \"-m\", \"tool\", p]).returncode"},
        "shells_out": {"sig": "(p) -> str",
            "body": "import subprocess\nreturn subprocess.run([\"pdftotext\", p], capture_output=True).stdout"}
    });
    got = exec_subprocess_tools(ir["tools"]);
    assert "spawns" in got and "spawns_alias" in got, str(got);
    # a plain binary is a real subprocess and must be left alone
    assert "shells_out" not in got, str(got);
}

test "the in-process runner keeps the CompletedProcess surface" {
    src = runpy_src();
    for needle in ["_sigil_run_py", "returncode", "stdout", "stderr", "compile(",
                   "runpy.run_module", "SystemExit"] {
        assert needle in src, "runpy_src is missing " + needle;
    }
    # it is pasted into a .jac module, so it must be fenced as a python block…
    assert src.startswith("::py::") and src.rstrip().endswith("::py::"), src[:60];
    # …and the fenced content must be valid Python
    import ast;
    ast.parse("\n".join(src.split("\n")[1:-1]));
}


test "the runner prefers the image python over the embedded one, and still falls back" {
    # exam-block-sequencing: the model's PySCIPOpt script ran INSIDE jac's python
    # (no pyscipopt there) and produced nothing; the task image had it all along.
    import os;
    import shutil;
    import sys;
    import tempfile;
    src = runpy_src();
    assert "_sigil_image_python" in src and "SIGIL_RUNPY_INPROC" in src and "ModuleNotFoundError" in src;
    ns: dict[str, any] = {"__builtins__": __builtins__, "__file__": os.path.abspath(__file__)};
    exec("\n".join(src.split("\n")[1:-1]), ns);
    d = tempfile.mkdtemp(prefix="sigil_runpy_");
    sp = os.path.join(d, "which.py");
    open(sp, "w").write("import sys, json\nprint(json.dumps({'exe': sys.executable, 'argv': sys.argv[1:]}))\n");
    p = ns["_sigil_run_py"]([sys.executable, sp, "a", "b"], capture_output=True, text=True);
    assert p.returncode == 0, p.stderr;
    import json;
    got = json.loads(p.stdout.strip().splitlines()[-1]);
    assert got["argv"] == ["a", "b"], got;
    img = ns["_sigil_image_python"]();
    if img { assert os.path.realpath(got["exe"]) != os.path.realpath(sys.executable) or os.path.realpath(img) == os.path.realpath(sys.executable), got; }
    # a module only the embedded interpreter has: the image run fails with ModuleNotFoundError and the in-process run takes over
    sp2 = os.path.join(d, "needs_embedded.py");
    open(sp2, "w").write("import sys\nimport _sigil_probe_only_here\nprint('ok', sys.executable)\n");
    sys.modules["_sigil_probe_only_here"] = type(sys)("_sigil_probe_only_here");
    p2 = ns["_sigil_run_py"]([sys.executable, sp2]);
    assert p2.returncode == 0 and "ok" in p2.stdout, (p2.returncode, p2.stdout, p2.stderr);
    os.environ["SIGIL_RUNPY_INPROC"] = "1";
    p3 = ns["_sigil_run_py"]([sys.executable, sp]);
    del os.environ["SIGIL_RUNPY_INPROC"];
    assert json.loads(p3.stdout.strip().splitlines()[-1])["exe"] == sys.executable;
}


test "a code-emitting tool's product imports reach the dependency manifest" {
    # drone-planning-control: the planner module lives in a multi-line string and is
    # exec()'d later, so `from scipy.interpolate import CubicSpline` never reached the
    # manifest; the preflight bound nothing and the exec died with ModuleNotFoundError
    # inside the artifact's own interpreter, while the task image shipped scipy all along.
    body = "def build_module(seed):\n    src = '''import numpy as np\nfrom scipy.interpolate import CubicSpline\n\n\ndef plan(x):\n    return CubicSpline([0, 1], [0, 1])(x)\n'''\n    return src\n";
    mods = _body_imports(body);
    assert "numpy" in mods, str(mods);
    assert "scipy" in mods, "an import inside the emitted module must be manifested: " + str(mods);
    # prose in a multi-line string is not code and must not add junk
    plain = "def doc():\n    return '''a note\nabout import duties and customs\n'''\n";
    assert _body_imports(plain) == [], str(_body_imports(plain));
}


test "the preflight binds the version the task image pins, not the latest release" {
    # earthquake-plate-calculation: the image pins pyproj==3.7.0 / geopandas==1.0.1, the artifact
    # bound the latest, and EPSG:4087 distances differ by 0.3% between PROJ releases — the tool
    # returned 3866.83 km where the image's own stack returns 3878.27, against a 0.01 km tolerance.
    src = preflight_src({"py": {"geopandas": {"pip": "geopandas", "tools": ["load_points_gdf"]}}, "bin": {}});
    assert "_image_version" in src, "no image-version probe in the preflight";
    assert "importlib.metadata" in src, "the probe must ask the image interpreter for its version";
    assert "_p + \"==\" + _ver" in src, "the bind must pin to the image's version";
    # the fallback path is still there for a module the image does not have
    assert "--upgrade" in src, "a module the image lacks must still bind the latest";
    # present-but-different is also a miss: the earthquake cell still returned 3866.83 after the
    # first parity fix because geopandas was already importable, so nothing was ever re-bound
    assert "_have != _img" in src, "a version that disagrees with the image must be re-bound";
}

