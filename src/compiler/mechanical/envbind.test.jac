"""envbind — the SkillRT Pass-2 analog: manifest extraction, install-time
probe, preflight emission. Pure code, no model."""

def _ir_with_tools(tools: dict) -> dict {
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
