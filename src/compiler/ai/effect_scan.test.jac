"""Tests — the effect scan, the effect gate's first reader.

Pure code, no model. These lock in what the scan's patterns name: a write follows
ais-spec (temporary files and a runtime's own bookkeeping included), and what the
scan cannot settle is unknown, never clean.
"""

import os;
import tempfile;

def _body(code: str) -> dict[str, any] {
    return scan_tool({"sig": "() -> str", "surface": "OBSERVE", "body": code}, "");
}

def _command(command: str, scripts: dict[str, str] = {}) -> dict[str, any] {
    d = tempfile.mkdtemp(prefix="sigil_scan_");
    os.makedirs(os.path.join(d, "scripts"), exist_ok=True);
    for (name, text) in scripts.items() {
        p = os.path.join(d, "scripts", name);
        os.makedirs(os.path.dirname(p), exist_ok=True);
        with open(p, "w") as fh { fh.write(text); }
    }
    return scan_tool({"sig": "() -> str", "surface": "OBSERVE", "command": command}, d);
}

def _skill_dir(scripts: dict[str, str]) -> str {
    d = tempfile.mkdtemp(prefix="sigil_scan_");
    os.makedirs(os.path.join(d, "scripts"), exist_ok=True);
    for (name, text) in scripts.items() {
        with open(os.path.join(d, "scripts", name), "w") as fh { fh.write(text); }
    }
    return d;
}

def _clean(r: dict[str, any]) -> bool {
    return r["code"] and r["writes"] == [] and r["unknown"] == [];
}

# --- files -----------------------------------------------------------------

test "a file opened for appending is a write; one opened for reading is not" {
    r = _body("def f(p):\n    with open(p, 'a') as h:\n        h.write('x')\n");
    assert len(r["writes"]) == 1 and "body:2" in r["writes"][0], str(r);
    assert _clean(_body("def f(p):\n    with open(p) as h:\n        return h.read()\n"));
    assert _clean(_body("def f(p):\n    return open(p, mode='rb').read()\n"));
}

test "a mode set at run time is unknown, not clean" {
    r = _body("def f(p, m):\n    return open(p, m)\n");
    assert r["writes"] == [] and len(r["unknown"]) == 1, str(r);
}

test "os, shutil and pathlib calls that change files are writes" {
    assert len(_body("import os\nos.remove('a.txt')\n")["writes"]) == 1;
    assert len(_body("from shutil import copy\ncopy('a', 'b')\n")["writes"]) == 1;
    assert len(_body("from pathlib import Path\nPath('out.json').write_text('{}')\n")["writes"]) == 1;
    assert len(_body("import os\nos.makedirs('out', exist_ok=True)\n")["writes"]) == 1;
}

test "a library write needs a path; with none, to_csv only returns text" {
    assert len(_body("import pandas as pd\npd.read_csv('a.csv').to_csv('b.csv')\n")["writes"]) == 1;
    assert _clean(_body("import pandas as pd\nprint(pd.read_csv('a.csv').to_csv(index=False))\n"));
    assert _clean(_body("import pandas as pd\ndf = pd.read_csv('a.csv')\ndf = df.rename(columns={'a': 'b'})\n"));
}

test "pathlib's open with a mode set at run time is unknown; rename and replace with target= are writes" {
    r = _body("from pathlib import Path\ndef f(m):\n    p = Path('a.txt')\n    return p.open(m)\n");
    assert r["writes"] == [] and len(r["unknown"]) == 1, str(r);
    assert len(_body("from pathlib import Path\nPath('a').rename(target='b')\n")["writes"]) == 1;
    assert len(_body("from pathlib import Path\nPath('a').replace(target='b')\n")["writes"]) == 1;
    assert _clean(_body("from pathlib import Path\nprint(Path('a.txt').open().read())\n"));
}

test "a bare save() writes wherever the object was opened, which is unknown" {
    r = _body("def f(c):\n    c.save()\n");
    assert r["writes"] == [] and len(r["unknown"]) == 1, str(r);
}

test "PIL's Image.open takes a path, not a mode" {
    assert _clean(_body("from PIL import Image\nprint(Image.open('x.png').size)\n"));
}

test "a temporary file is a write (ais-spec 4.3.2, surface workspace); an in-memory one is not" {
    code = "\n".join([
        "import os, tempfile",
        "d = tempfile.mkdtemp()",
        "p = os.path.join(d, 'x.txt')",
        "with open(p, 'w') as h:",
        "    h.write('x')",
        ""
    ]);
    r = _body(code);
    assert len([w for w in r["writes"] if "body:2" in w]) == 1 and len([w for w in r["writes"] if "body:4" in w]) == 1, str(r);
    assert len(_body("import tempfile\nf = tempfile.NamedTemporaryFile(delete=True)\n")["writes"]) == 1;
    assert len(_body("with open('/tmp/x.txt', 'w') as h:\n    h.write('x')\n")["writes"]) == 1;
    mem = "import io\nbuf = io.BytesIO()\nimport matplotlib.pyplot as plt\nplt.savefig(buf)\n";
    assert _clean(_body(mem)), str(_body(mem));
}

test "Path.rename and Path.replace are writes; str.replace and DataFrame.rename are not" {
    assert len(_body("from pathlib import Path\nPath('a.txt').rename('b.txt')\n")["writes"]) == 1;
    assert len(_body("from pathlib import Path\np = Path('out') / 'a.tmp'\np.replace(p.with_suffix('.json'))\n")["writes"]) == 1;
    assert len(_body("from pathlib import Path\ndef f(d: Path):\n    for x in d.glob('*.log'):\n        x.rename(x.with_suffix('.old'))\n")["writes"]) == 1;
    assert _clean(_body("s = 'a-b'.replace('-', '_')\n"));
    assert _clean(_body("import pandas as pd\ndf = pd.read_csv('a.csv').rename(columns={'a': 'b'})\n"));
    r = _body("def f(x, y):\n    x.rename(y)\n");
    assert r["writes"] == [] and len(r["unknown"]) == 1, str(r);
}

# --- network, database, processes ------------------------------------------

test "posting data is a write; fetching is not" {
    assert len(_body("import requests\nrequests.post('https://x', json={})\n")["writes"]) == 1;
    assert len(_body("import requests\ns = requests.Session()\ns.post('https://x')\n")["writes"]) == 1;
    assert _clean(_body("import requests\ns = requests.Session()\ns.get('https://x')\n"));
}

test "a database insert is a write; a select is not" {
    assert len(_body("import sqlite3\nc = sqlite3.connect('a.db')\nc.execute('INSERT INTO t VALUES (1)')\n")["writes"]) == 1;
    assert _clean(_body("import sqlite3\nc = sqlite3.connect(':memory:')\nc.execute('SELECT * FROM t')\n"));
    assert _clean(_body("import sqlite3\nc = sqlite3.connect('file:a.db?mode=ro', uri=True)\nc.execute('SELECT * FROM t')\n"));
}

test "a write is found whatever the SQL's spacing; SQL built at run time and a database file are unknown" {
    assert len(_body("import sqlite3\nc = sqlite3.connect(':memory:')\nc.execute('INSERT\\nINTO t VALUES (1)')\n")["writes"]) == 1;
    assert len(_body("import sqlite3\nc = sqlite3.connect(':memory:')\nc.executescript('SELECT 1; DELETE FROM t')\n")["writes"]) == 1;
    r = _body("import sqlite3\nc = sqlite3.connect(':memory:')\ndef f(q):\n    c.execute(q)\n");
    assert r["writes"] == [] and len(r["unknown"]) == 1, str(r);
    # connecting creates the database file when it is missing
    r = _body("import sqlite3\nc = sqlite3.connect('a.db')\nc.execute('SELECT * FROM t')\n");
    assert r["writes"] == [] and len(r["unknown"]) == 1, str(r);
}

test "npm and npx write their debug log (W9); --logs-max=0 turns it off" {
    assert len(_body("import subprocess\nsubprocess.run(['npm', 'run', 'build'])\n")["writes"]) == 1;
    assert len(_body("import subprocess\nsubprocess.run('npx tsc --noEmit', shell=True)\n")["writes"]) == 1;
    assert len(_command("npm run smoke")["writes"]) == 1;
    r = _command("npm --logs-max=0 run smoke");
    assert r["writes"] == [] and len(r["unknown"]) == 1, str(r);
}

test "installing packages is a write, even through sys.executable -m pip" {
    assert len(_command("pip install -r requirements.txt")["writes"]) == 1;
    code = "import subprocess, sys\nsubprocess.run([sys.executable, 'scripts/run.py'])\nsubprocess.run([sys.executable, '-m', 'pip', 'install', 'x'])\n";
    r = scan_tool({"sig": "() -> str", "surface": "OBSERVE", "body": code}, _skill_dir({"run.py": "print(1)\n"}));
    assert len([w for w in r["writes"] if "body:3" in w and "installs" in w]) == 1 and r["unknown"] == [], str(r);
}

test "a process that starts Python with -m or -c is not taken for a bundled script" {
    code = "import subprocess, sys\nsubprocess.run([sys.executable, 'scripts/run.py'])\nsubprocess.run([sys.executable, '-c', 'import os'])\n";
    r = scan_tool({"sig": "() -> str", "surface": "OBSERVE", "body": code}, _skill_dir({"run.py": "print(1)\n"}));
    assert r["writes"] == [] and len([u for u in r["unknown"] if "body:3" in u]) == 1, str(r);
}

test "a process that starts Python is taken for a bundled script only when it names one" {
    d = _skill_dir({"run.py": "print(1)\n"});
    code = "import subprocess, sys\nsubprocess.run([sys.executable, 'scripts/run.py'])\nsubprocess.run([sys.executable, '/opt/opaque.py'])\n";
    r = scan_tool({"sig": "() -> str", "surface": "OBSERVE", "body": code}, d);
    assert len([u for u in r["unknown"] if "body:3" in u]) == 1 and len([u for u in r["unknown"] if "body:2" in u]) == 0, str(r);
    # a shell string that runs a bundled script is read like a command, every operation in it
    code = "import subprocess\nsubprocess.run('python scripts/run.py && rm -rf out', shell=True)\n";
    r = scan_tool({"sig": "() -> str", "surface": "OBSERVE", "body": code}, d);
    assert len([w for w in r["writes"] if "rm" in w]) == 1, str(r);
}

test "an in-memory file is recognized by the call that makes it, not by a name" {
    assert len(_body("with open('StringIO.txt', 'w') as h:\n    h.write('x')\n")["writes"]) == 1;
    # a name that held a buffer and was then bound to a path is not a buffer
    assert len(_body("import io\nbuf = io.StringIO()\nbuf = 'out.txt'\nopen(buf, 'w').write('x')\n")["writes"]) == 1;
    assert _clean(_body("import io\nbuf = io.StringIO()\nbuf.write('x')\nopen(buf.getvalue()).read()\n"));
}

test "a bundled script the scan cannot read is unknown, never clean" {
    d = _skill_dir({"a.py": "open('out.txt', 'w').write('x')\n"});
    p = os.path.join(d, "scripts", "a.py");
    os.chmod(p, 0);
    try {
        if not os.access(p, os.R_OK) {   # root reads it anyway
            r = scan_tool({"sig": "() -> str", "surface": "OBSERVE", "command": "python scripts/a.py"}, d);
            assert r["writes"] == [] and len([u for u in r["unknown"] if "scripts/a.py" in u]) == 1, str(r);
        }
    } finally {
        os.chmod(p, 420);
    }
}

test "a bundled script that points outside the skill folder is not read" {
    outside = tempfile.mkdtemp(prefix="sigil_scan_out_");
    with open(os.path.join(outside, "secret.py"), "w") as fh { fh.write("TOKEN = 'OUTSIDE_MARKER'\nopen('x', 'w')\n"); }
    d = _skill_dir({});
    os.symlink(os.path.join(outside, "secret.py"), os.path.join(d, "scripts", "helper.py"));
    tool = {"sig": "() -> str", "surface": "OBSERVE", "command": "python scripts/helper.py"};
    r = scan_tool(tool, d);
    assert r["writes"] == [] and len(r["unknown"]) == 1, str(r);
    assert "OUTSIDE_MARKER" not in tool_source(tool, d);
}

test "starting a process, dynamic code and unknown libraries are left to the model" {
    for code in ["import subprocess\nsubprocess.run(['pdftotext', 'a.pdf', '-'])\n",
                 "eval(input())\n",
                 "import ehr_client\nehr_client.Client().get('V-1')\n",
                 "import socket\n"] {
        r = _body(code);
        assert r["writes"] == [] and len(r["unknown"]) == 1, code + " -> " + str(r);
    }
}

test "code that does not parse is unknown" {
    r = _body("def f(:\n");
    assert r["writes"] == [] and r["unknown"] == ["body does not parse"], str(r);
}

# --- commands and bundled scripts -------------------------------------------

test "a bundled script the command runs is scanned, with its local imports" {
    r = _command("python scripts/fetch.py {visit_id}", {
        "fetch.py": "import helpers\nprint(helpers.get())\n",
        "helpers.py": "def get():\n    open('trace.log', 'a').write('x')\n    return 1\n"
    });
    assert len([w for w in r["writes"] if "scripts/helpers.py:2" in w]) == 1, str(r);
    # importing the bundled module writes its bytecode cache (W10)
    assert len([w for w in r["writes"] if "scripts/fetch.py:1" in w and "__pycache__" in w]) == 1, str(r);
    assert len(r["writes"]) == 2 and r["unknown"] == [], str(r);
}

test "importing a bundled module writes its __pycache__ (W10); a stdlib import does not" {
    tool = {"sig": "() -> str", "surface": "OBSERVE", "body": "import json\nimport dialogue_graph\nprint(json.dumps(dialogue_graph.build()))\n"};
    r = scan_tool(tool, _skill_dir({"dialogue_graph.py": "def build():\n    return {}\n"}));
    assert len(r["writes"]) == 1 and "body:2" in r["writes"][0] and "__pycache__" in r["writes"][0], str(r);
    assert _clean(_body("import json\nprint(json.dumps({}))\n"));
}

test "a local package is followed through its __init__ and relative imports" {
    r = _command("python scripts/validate.py {doc}", {
        "validate.py": "from validation import check\ncheck()\n",
        "validation/__init__.py": "from .core import check\n",
        "validation/core.py": "def check():\n    open('report.txt', 'w').write('x')\n"
    });
    assert len([w for w in r["writes"] if "scripts/validation/core.py:2" in w]) == 1, str(r);
    # the imports write bytecode caches: `from validation import`, and the relative `from .core import`
    assert len([w for w in r["writes"] if "__pycache__" in w]) == 2, str(r);
    assert r["unknown"] == [], str(r);
}

test "a script the scan cannot find is unknown, never clean" {
    r = _command("python scripts/missing.py {x}");
    assert r["writes"] == [] and len(r["unknown"]) == 1, str(r);
}

test "a shell redirect or file command is a write; a program the scan cannot read is unknown" {
    assert len(_command("echo hi > out.txt")["writes"]) == 1;
    assert _clean(_command("python scripts/a.py 2>/dev/null", {"a.py": "print(1)\n"}));
    assert _clean(_command("python scripts/a.py | tee /dev/null", {"a.py": "print(1)\n"}));
    assert len(_command("python scripts/a.py | tee log.txt", {"a.py": "print(1)\n"})["writes"]) == 1;
    assert len(_command("echo hi > /tmp/out.txt")["writes"]) == 1;
    assert len(_command("mkdir -p out")["writes"]) == 1;
    r = _command("pandoc in.md -o out.pdf");
    assert r["writes"] == [] and len(r["unknown"]) == 1, str(r);
}

test "sort -o and uniq's output argument write files; sorting and counting to stdout do not" {
    assert len(_command("sort -o out.txt in.txt")["writes"]) == 1;
    assert len(_command("sort --output=out.txt in.txt")["writes"]) == 1;
    assert len(_command("uniq in.txt out.txt")["writes"]) == 1;
    assert _clean(_command("sort -u in.txt"));
    assert _clean(_command("uniq -c -f 1 in.txt"));
}

test "a tool with no code has nothing to scan" {
    r = scan_tool({"sig": "() -> str", "surface": "OBSERVE"}, "");
    assert (not r["code"]) and r["writes"] == [] and r["unknown"] == [];
}

test "tool_source gives the model the code and scripts, never the label or the doc" {
    d = tempfile.mkdtemp(prefix="sigil_scan_");
    os.makedirs(os.path.join(d, "scripts"), exist_ok=True);
    with open(os.path.join(d, "scripts", "fetch.py"), "w") as fh { fh.write("TRACE = 'EHR_CLIENT_TRACE'\n"); }
    src = tool_source({"sig": "(v) -> str", "surface": "OBSERVE", "doc": "Print the visit record.",
                       "command": "python scripts/fetch.py {v}"}, d);
    assert "EHR_CLIENT_TRACE" in src and "python scripts/fetch.py" in src;
    assert "OBSERVE" not in src and "Print the visit record" not in src;
}
