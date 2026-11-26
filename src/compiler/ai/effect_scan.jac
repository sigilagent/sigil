"""Effect scan — what a tool's bound code does outside the run, read from the code alone.

The effect gate's first reader (effect_gate.jac). It parses a tool's inline `body` and
the bundled Python scripts its `body` or `command` names, and runs nothing. It matches
fixed patterns, and says what it could not follow:

  writes   a call that changes state outside the process: a file opened for writing,
           created, moved or deleted, temporary ones included; a path a library writes
           (`to_csv(path)`, `save(path)`); data posted over the network; a database
           write; a package install; an import of a bundled module (it writes the
           module's `__pycache__`); `npm` or `npx` (they write a debug log)
  unknown  what reading cannot settle: a process the tool starts (unless it provably
           runs a bundled Python script, which is scanned on its own), a library with
           no rules here, a bundled file that is not Python or cannot be read, a mode
           set at run time

A tool with neither is clean as far as the patterns go: a call no pattern names is
not seen. ais-spec §4.3.2 makes a temporary file an ACT effect (surface workspace),
so a temp write is a write; only an in-memory file (BytesIO, StringIO) is not.
Whatever is unknown goes to the compile model, which reads the same code through
tool_source, without the tool's label or doc.
"""

import ast;
import re;
import sys;
import from pathlib { Path }

glob MAX_SCRIPT: int = 60000;
glob _CUT_NOTE: str = "(Truncated: the file has more than ";
glob _UNREAD_NOTE: str = "(The file cannot be read.)";
glob _SCRIPT_EXTS: list[str] = ["py", "sh", "bash", "js", "mjs", "ts", "rb", "pl"];

# Calls that change the filesystem, by origin. The destination is the first argument,
# or the second for the ones in _DEST_SECOND.
glob _FS_CALLS: list[str] = [
    "os.remove", "os.unlink", "os.rmdir", "os.removedirs", "os.rename", "os.renames", "os.replace",
    "os.mkdir", "os.makedirs", "os.chmod", "os.chown", "os.truncate", "os.symlink", "os.link", "os.utime",
    "shutil.copy", "shutil.copy2", "shutil.copyfile", "shutil.copytree", "shutil.move", "shutil.rmtree",
    "shutil.make_archive", "shutil.unpack_archive", "urllib.request.urlretrieve", "pandas.ExcelWriter",
    "logging.FileHandler", "logging.handlers.RotatingFileHandler", "logging.handlers.TimedRotatingFileHandler",
    "tempfile.mkdtemp", "tempfile.mkstemp", "tempfile.NamedTemporaryFile", "tempfile.TemporaryDirectory",
    "tempfile.TemporaryFile"
];
glob _DEST_SECOND: list[str] = ["os.rename", "os.renames", "os.replace", "os.symlink", "os.link", "shutil.copy",
                                "shutil.copy2", "shutil.copyfile", "shutil.copytree", "shutil.move",
                                "shutil.unpack_archive", "urllib.request.urlretrieve"];
# pathlib methods: they change the path they are called on.
glob _FS_METHODS: list[str] = ["write_text", "write_bytes", "unlink", "rmdir", "mkdir", "touch", "symlink_to",
                               "hardlink_to", "chmod"];
# pathlib methods whose names other types share (`str.replace`, `DataFrame.rename`): a write
# when called on a path, unknown when called on something else with one positional argument.
glob _PATH_MOVES: list[str] = ["rename", "replace"];
# What gives a pathlib path: these calls, these methods, and `a / b`.
glob _PATH_MAKERS: list[str] = ["pathlib.Path", "pathlib.PurePath", "pathlib.PosixPath", "Path", "PurePath"];
glob _PATH_METHODS: list[str] = ["with_suffix", "with_name", "with_stem", "joinpath", "resolve", "absolute",
                                 "expanduser"];
# Library methods that write to the path they are given (pandas, numpy, matplotlib, PIL,
# openpyxl, python-docx/pptx, OpenCV). With no path, `to_csv()` and the like only
# return text; a bare `save()` writes wherever the object was opened, which is unknown.
glob _SAVE_METHODS: list[str] = ["to_csv", "to_excel", "to_json", "to_parquet", "to_feather", "to_hdf", "to_pickle",
                                 "to_stata", "to_html", "to_markdown", "to_latex", "to_xml", "savefig", "save",
                                 "savez", "savez_compressed", "savetxt", "imwrite", "imsave", "extractall"];
glob _PATH_KWS: list[str] = ["path_or_buf", "buf", "excel_writer", "path", "fname", "fp", "file", "filename", "f"];
# Openers whose mode is the second argument; anything else called `.open` is pathlib-style.
glob _OPENERS: list[str] = ["open", "io.open", "codecs.open", "gzip.open", "bz2.open", "lzma.open", "tarfile.open",
                            "zipfile.ZipFile"];
glob _SENDS: list[str] = ["requests.post", "requests.put", "requests.patch", "requests.delete",
                          "httpx.post", "httpx.put", "httpx.patch", "httpx.delete"];
glob _CLIENT_RE: str = r"^(requests|httpx|aiohttp|urllib3)\.";
glob _EXEC: list[str] = ["subprocess.run", "subprocess.call", "subprocess.check_call", "subprocess.check_output",
                         "subprocess.Popen", "os.system", "os.popen", "asyncio.create_subprocess_exec",
                         "asyncio.create_subprocess_shell"];
glob _DYNAMIC: list[str] = ["exec", "eval", "compile", "__import__", "importlib.import_module", "runpy.run_path",
                            "runpy.run_module"];
glob _WRITE_SQL: list[str] = ["INSERT", "UPDATE", "DELETE", "REPLACE", "CREATE", "DROP", "ALTER"];
# Third-party libraries whose writes the rules above name. Any other library is unknown.
glob _KNOWN_LIBS: list[str] = ["pandas", "numpy", "scipy", "sklearn", "matplotlib", "seaborn", "PIL", "cv2", "pypdf",
                               "PyPDF2", "pdfplumber", "fitz", "pymupdf", "openpyxl", "xlrd", "docx", "pptx", "yaml",
                               "bs4", "lxml", "requests", "httpx", "markdown", "jinja2", "tabulate", "chardet",
                               "dateutil", "pytz", "tqdm", "rich", "click", "pydantic", "regex", "networkx", "sympy",
                               "defusedxml", "markdownify", "html2text"];
# Standard-library modules that talk to the network below the rules above.
glob _NET_STDLIB: list[str] = ["socket", "socketserver", "ftplib", "http.client", "http.server", "xmlrpc", "imaplib",
                               "poplib", "telnetlib"];
# Shell commands that only read, and ones that change files.
glob _SHELL_READ: list[str] = ["cd", "echo", "cat", "ls", "head", "tail", "wc", "grep", "true", "test", "printf",
                               "sort", "uniq", "jq", "pwd", "tee"];  # tee's file arguments: the redirect check
glob _SHELL_WRITE: list[str] = ["rm", "mv", "cp", "mkdir", "touch", "rmdir", "ln", "chmod", "chown", "truncate", "dd"];
# An in-memory file: a write there changes nothing outside the process. A temporary
# file is not one: ais-spec §4.3.2 makes it an ACT effect (surface workspace).
glob _MEMORY_CALLS: list[str] = ["io.BytesIO", "io.StringIO", "BytesIO", "StringIO"];
# Programs that write on every run: npm and npx keep a debug log under ~/.npm/_logs,
# unless `--logs-max=0` turns it off.
glob _LOGGING_PROGS: list[str] = ["npm", "npx"];

def scan_tool(tool: any, skill_dir: str = "") -> dict[str, any] {
    # -> {"code": the tool has a body or command, "writes": [evidence], "unknown": [reasons]}
    out: dict[str, any] = {"code": False, "writes": [], "unknown": []};
    if not isinstance(tool, dict) { return out; }
    body = str(tool.get("body") or "");
    command = str(tool.get("command") or "");
    if not (body.strip() or command.strip()) { return out; }
    out["code"] = True;
    files = _files(skill_dir);
    found = _named(body + "\n" + command, files);
    py = [f for f in found if f.endswith(".py")];
    local = list(_index(files)["by_module"].keys());
    if body.strip() { _scan_py(body, "body", py, local, out); }
    if command.strip() { _scan_command(command, found, out); }
    for f in found {
        if not f.endswith(".py") {
            _add(out["unknown"], "runs " + f + ", which the scan does not read");
            continue;
        }
        text = _read(files[f]);
        if text is None { _add(out["unknown"], f + " cannot be read"); }
        else { _scan_py(text, f, py, local, out); }
    }
    return out;
}

def tool_source(tool: any, skill_dir: str = "") -> str {
    # The code of one AG-IR tool for the model to read: body, command and the bundled
    # scripts they name. Its surface, doc and serves are left out on purpose. "" when
    # the tool has no code.
    if not isinstance(tool, dict) { return ""; }
    body = str(tool.get("body") or "");
    command = str(tool.get("command") or "");
    if not (body.strip() or command.strip()) { return ""; }
    files = _files(skill_dir);
    parts: list[str] = ["The bundled scripts below are files in the skill folder that the tool's code names or imports; "
                        + "the tool may run them (relative to the working directory) or only refer to them.\n"];
    if body.strip() { parts.append("## Tool body\n\n```python\n" + body.rstrip() + "\n```\n"); }
    if command.strip() {
        parts.append("## Tool command (arguments in braces are filled in at run time)\n\n```\n" + command.strip() + "\n```\n");
    }
    for f in _named(body + "\n" + command, files) {
        text = _read(files[f]);
        if text is None {
            parts.append("## Bundled script `" + f + "`\n\n" + _UNREAD_NOTE + "\n");
            continue;
        }
        cut = "";
        if len(text) > MAX_SCRIPT {
            text = text[:MAX_SCRIPT];
            cut = "\n" + _CUT_NOTE + str(MAX_SCRIPT) + " characters.)\n";
        }
        parts.append("## Bundled script `" + f + "`\n\n```\n" + text.rstrip() + "\n```\n" + cut);
    }
    return "\n".join(parts);
}

def source_complete(src: str) -> bool {
    # Did tool_source show all of the code? A script cut at MAX_SCRIPT or one that cannot
    # be read is not shown whole, so a reader's "no write" cannot clear what the scan found.
    return (_CUT_NOTE not in src) and (_UNREAD_NOTE not in src);
}

# --- finding the code ------------------------------------------------------

def _files(skill_dir: str) -> dict[str, any] {
    # path inside the skill folder (`scripts/fetch_visit.py`) -> path, for every bundled script.
    # A link that resolves outside the folder is left out: the folder is untrusted, and
    # what it links to is not the skill's code (a script it names is then not found).
    out: dict[str, any] = {};
    if not skill_dir { return out; }
    base = Path(skill_dir).resolve();
    if not base.is_dir() { return out; }
    for p in sorted(base.rglob("*")) {
        if p.is_file() and (p.suffix.lstrip(".") in _SCRIPT_EXTS) and p.resolve().is_relative_to(base) {
            out[p.relative_to(base).as_posix()] = p;
        }
    }
    return out;
}

def _index(files: dict[str, any]) -> dict[str, any] {
    # by_name: file name -> files; by_module: what an `import X` can reach -> files, where X
    # is a module's stem or a package's folder (its __init__.py; relative imports inside the
    # package are followed from there)
    by_name: dict[str, list[str]] = {};
    by_module: dict[str, list[str]] = {};
    for rel in files {
        name = rel.rsplit("/", 1)[-1];
        by_name.setdefault(name, []).append(rel);
        if name == "__init__.py" and "/" in rel {
            by_module.setdefault(rel.rsplit("/", 2)[-2], []).append(rel);
        } elif name.endswith(".py") {
            by_module.setdefault(name[:-3], []).append(rel);
        }
    }
    return {"by_name": by_name, "by_module": by_module};
}

def _named(text: str, files: dict[str, any]) -> list[str] {
    # bundled files the text names (`scripts/fetch_visit.py`) or imports (`import helpers`,
    # `from validation import X`), then what those import, transitively
    ix = _index(files);
    found: list[str] = [];
    for m in re.finditer(r"([A-Za-z0-9_\-]+\.(?:py|sh|bash|js|mjs|ts|rb|pl))\b", text) {
        for rel in ix["by_name"].get(m.group(1), []) { _add(found, rel); }
    }
    for m in re.finditer(r"^\s*(?:from|import)\s+([A-Za-z0-9_]+)", text, re.M) {
        for rel in ix["by_module"].get(m.group(1), []) { _add(found, rel); }
    }
    todo = list(found);
    while todo {
        for g in _imports_of(todo.pop(), files, ix) {
            if g not in found { found.append(g); todo.append(g); }
        }
    }
    return found;
}

def _imports_of(rel: str, files: dict[str, any], ix: dict[str, any]) -> list[str] {
    # bundled files that the Python file `rel` imports: modules and packages by name, and
    # relative imports (`from .docx import X`) resolved against the file's own folder
    out: list[str] = [];
    if not rel.endswith(".py") { return out; }
    tree = _parse(_read(files[rel]) or "");
    if tree is None { return out; }
    here = rel.rsplit("/", 1)[0] if "/" in rel else "";
    for n in ast.walk(tree) {
        if isinstance(n, ast.Import) {
            for a in n.names {
                for g in ix["by_module"].get(a.name.split(".")[0], []) { _add(out, g); }
            }
        } elif isinstance(n, ast.ImportFrom) and (not n.level) and n.module {
            for g in ix["by_module"].get(n.module.split(".")[0], []) { _add(out, g); }
        } elif isinstance(n, ast.ImportFrom) and n.level {
            base = here;
            for k in range(n.level - 1) { base = base.rsplit("/", 1)[0] if "/" in base else ""; }
            stems = [n.module.replace(".", "/")] if n.module else [a.name for a in n.names];
            for s in stems {
                for cand in [s + ".py", s + "/__init__.py"] {
                    g = (base + "/" + cand) if base else cand;
                    if g in files { _add(out, g); }
                }
            }
        }
    }
    return out;
}

def _read(path: any) -> any {
    # the file's text, or None when it cannot be read: an unreadable script is not an
    # empty one, which would parse and come out clean
    try { return Path(path).read_text(encoding="utf-8", errors="replace"); }
    except Exception { return None; }
}

def _parse(text: str) -> any {
    try { return ast.parse(text); }
    except Exception { return None; }
}

def _add(xs: list[str], s: str) -> None {
    if s not in xs { xs.append(s); }
}

# --- the shell command -----------------------------------------------------

def _scan_command(command: str, found: list[str], out: dict[str, any], where: str = "command") -> None {
    # `where` names the command in the evidence: the tool's `command`, or a shell string
    # its Python code runs (`body:3 runs a shell command`)
    one_line = re.sub(r"\s+", " ", command).strip();
    names = [f.rsplit("/", 1)[-1] for f in found];
    dests = [d for d in re.findall(r"(?:^|[^<>&|0-9])>{1,2}\s*([^&\s]+)", command) if not d.startswith("/dev/")];
    if dests or re.search(r"\btee\b(\s+-[A-Za-z-]+)*\s+(?!/dev/)[^\s|;&]", command) {
        _add(out["writes"], where + " redirects output to a file: " + one_line[:100]);
    }
    for seg in re.split(r"&&|\|\||[;|]", command) {
        words = [w for w in seg.split() if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", w)];
        if words and words[0] == "env" { words = words[1:]; }
        if not words { continue; }
        prog = words[0].split("/")[-1];
        if prog in _SHELL_READ and not _writes_through_args(prog, words[1:]) { continue; }
        if prog in _SHELL_READ {
            _add(out["writes"], where + " runs `" + prog + "` with an output file: " + seg.strip()[:100]);
        } elif prog in _LOGGING_PROGS and "--logs-max=0" not in seg {
            _add(out["writes"], where + " runs `" + prog + "`, which writes its debug log under ~/.npm/_logs: " + seg.strip()[:100]);
        } elif _installs(seg) {
            _add(out["writes"], where + " installs packages: " + seg.strip()[:100]);
        } elif prog in _SHELL_WRITE {
            _add(out["writes"], where + " runs `" + prog + "`: " + seg.strip()[:100]);
        } elif re.match(r"^python[0-9.]*$", prog) {
            scripts = [w for w in words[1:] if w.endswith(".py")];
            if (not scripts) or len([s for s in scripts if not _bundled(s, names)]) > 0 {
                _add(out["unknown"], where + " runs Python code the scan cannot find: " + seg.strip()[:100]);
            }
        } elif len([w for w in words[1:] if _bundled(w, names)]) == 0 {
            _add(out["unknown"], where + " runs `" + prog + "`, which the scan cannot read");
        }
    }
}

def _writes_through_args(prog: str, args: list[str]) -> bool {
    # The reading programs that can still write a file through an argument, no redirect
    # needed: `sort -o out.txt in.txt`, and uniq's second file (`uniq in.txt out.txt`).
    if prog == "sort" {
        return len([a for a in args if a.startswith("--output") or re.match(r"^-[A-Za-z]*o", a)]) > 0;
    }
    if prog == "uniq" {
        files: list[str] = [];
        takes_number = False;
        for a in args {
            if takes_number { takes_number = False; }
            elif a in ["-f", "-s", "-w"] { takes_number = True; }   # these take a number
            elif not (a.startswith("-") and a != "-") { files.append(a); }
        }
        return len(files) > 1;
    }
    return False;
}

def _bundled(word: str, names: list[str]) -> bool {
    # a script argument that names a bundled file: `scripts/fetch.py`, `{skill_dir}/fetch.py`.
    # An absolute path is somewhere else, whatever its file name (`/opt/fetch.py`).
    w = word.strip("'\"");
    return Path(w).name in names and not (w.startswith("/") or w.startswith("~"));
}

# --- Python code -----------------------------------------------------------

def _scan_py(text: str, loc: str, py: list[str], local: list[str], out: dict[str, any]) -> None {
    tree = _parse(text);
    if tree is None {
        _add(out["unknown"], loc + " does not parse");
        return;
    }
    al = _aliases(tree);
    memory = _memory_names(tree, al);
    clients = _client_names(tree, al);
    paths = _path_names(tree, al);
    for n in ast.walk(tree) {
        if isinstance(n, ast.Import) or (isinstance(n, ast.ImportFrom) and not n.level) {
            mods = [a.name for a in n.names] if isinstance(n, ast.Import) else [str(n.module or "")];
            for m in mods { _scan_import(m, loc + ":" + str(n.lineno), local, out); }
        } elif isinstance(n, ast.ImportFrom) and n.level {
            _add(out["writes"], loc + ":" + str(n.lineno) + " imports a bundled module (relative import "
                 + ast.unparse(n)[:60] + "), which writes its __pycache__ bytecode");
        } elif isinstance(n, ast.Call) {
            _scan_call(n, loc + ":" + str(n.lineno), al, memory, clients, py, paths, out);
        }
    }
}

def _scan_import(m: str, loc: str, local: list[str], out: dict[str, any]) -> None {
    top = m.split(".")[0];
    if not top { return; }
    if top in local {
        _add(out["writes"], loc + " imports the bundled module `" + top + "`, which writes its __pycache__ bytecode");
        return;
    }
    if len([x for x in _NET_STDLIB if m == x or m.startswith(x + ".")]) > 0 {
        _add(out["unknown"], loc + " uses the network library `" + m + "`");
    } elif (top not in sys.stdlib_module_names) and (top not in _KNOWN_LIBS) {
        _add(out["unknown"], loc + " uses `" + top + "`, a library the scan has no rules for");
    }
}

def _scan_call(n: any, loc: str, al: dict[str, str], memory: list[str], clients: list[str], py: list[str],
               paths: list[str], out: dict[str, any]) -> None {
    fname = _dotted(n.func, al);
    attr = str(n.func.attr) if isinstance(n.func, ast.Attribute) else fname;
    seen = loc + " " + _short(n);
    if (fname in _EXEC) or fname.startswith("os.exec") or fname.startswith("os.spawn") {
        # A bundled Python script the call runs is scanned on its own, so the call itself
        # is settled only when it provably runs one: a shell string is read like a command,
        # every operation in it; an argv list must start Python (`sys.executable`,
        # `python3`) on a bundled script. Anything else starts a process the scan cannot see.
        call = ast.unparse(n);
        prog = _argv0(n);
        shell = _const(n.args[0]) if n.args else None;
        if prog in _LOGGING_PROGS and "--logs-max=0" not in call {
            _add(out["writes"], seen + " (runs `" + prog + "`, which writes its debug log under ~/.npm/_logs)");
        } elif _installs(call) {
            _add(out["writes"], seen + " (installs packages)");
        } elif shell is not None and str(shell).strip() {
            _scan_command(str(shell), py, out, loc + " runs a shell command that");
        } elif not _runs_bundled(n, py) {
            _add(out["unknown"], seen + " starts a process");
        }
    } elif fname in _DYNAMIC {
        _add(out["unknown"], seen + " runs code built at run time");
    } elif fname in _OPENERS {
        _scan_mode(n, _arg(n, 1, ["mode"]), _arg(n, 0, ["file", "filename", "name"]), seen, memory, al, out);
    } elif attr == "open" and isinstance(n.func, ast.Attribute) {
        # pathlib-style `p.open("w")`; `Image.open("x.png")` passes a path, not a mode. On a
        # path, a first argument set at run time is a mode the scan cannot see (`p.open(m)`).
        mode = _arg(n, -1, ["mode"]);
        if (mode is None) and n.args {
            first = _const(n.args[0]);
            if (first is not None and re.fullmatch(r"[rwaxbtU+]{1,4}", str(first))) or (first is None and _is_path(n.func.value, al, paths)) {
                mode = n.args[0];
            }
        }
        _scan_mode(n, mode, n.func.value, seen, memory, al, out);
    } elif fname in _FS_CALLS {
        dest = _arg(n, 1, ["dst", "filename", "extract_dir"]) if fname in _DEST_SECOND else _arg(n, 0, ["path", "filename", "name", "base_name"]);
        if not _is_memory(dest, memory, al) { _add(out["writes"], seen); }
    } elif fname == "logging.basicConfig" and _arg(n, -1, ["filename"]) is not None {
        _add(out["writes"], seen);
    } elif attr in _PATH_MOVES and isinstance(n.func, ast.Attribute) and _move_target(n) is not None {
        if _is_path(n.func.value, al, paths) { _add(out["writes"], seen); }
        else { _add(out["unknown"], seen + " may rename a file"); }
    } elif attr in _FS_METHODS and isinstance(n.func, ast.Attribute) {
        if not _is_memory(n.func.value, memory, al) { _add(out["writes"], seen); }
    } elif attr in _SAVE_METHODS and isinstance(n.func, ast.Attribute) {
        target = _arg(n, 0, _PATH_KWS);
        if target is None and attr == "save" {
            _add(out["unknown"], seen + " saves to wherever the object was opened");
        } elif target is not None and not _is_memory(target, memory, al) and "sys.stdout" not in ast.unparse(target) {
            _add(out["writes"], seen);
        } elif target is None and attr == "extractall" {
            _add(out["writes"], seen);
        }
    } elif _is_send(n, fname, attr, clients) {
        _add(out["writes"], seen + " (network)");
    } elif fname == "sqlite3.connect" {
        # connecting creates the database file when it is missing; an in-memory or a
        # read-only database does not
        db = _const(_arg(n, 0, ["database"]));
        if not (db is not None and (db == ":memory:" or "mode=ro" in db)) {
            _add(out["unknown"], seen + " may create the database file");
        }
    } elif attr in ["execute", "executemany", "executescript"] and n.args {
        sql = _const(n.args[0]);
        if sql is None {
            _add(out["unknown"], seen + " runs SQL built at run time");
        } elif _sql_writes(str(sql)) {
            _add(out["writes"], seen + " (database)");
        }
    }
}

def _move_target(n: any) -> any {
    # the destination of a `rename`/`replace` call shaped like pathlib's, positional or
    # `target=`; None for other shapes (`str.replace(a, b)`, `df.rename(columns={...})`)
    t: any = None;
    if len(n.args) == 1 and not n.keywords { t = n.args[0]; }
    elif (not n.args) and len(n.keywords) == 1 and n.keywords[0].arg == "target" { t = n.keywords[0].value; }
    if t is None or isinstance(t, (ast.Dict, ast.DictComp)) { return None; }
    return t;
}

def _sql_writes(sql: str) -> bool {
    # any statement that starts with a writing keyword, whatever the spacing and comments
    # (`INSERT\nINTO`, `SELECT 1; DELETE FROM t`)
    text = re.sub(r"--[^\n]*|/\*.*?\*/", " ", sql, flags=re.S);
    for stmt in text.split(";") {
        words = [w.upper() for w in re.findall(r"[A-Za-z]+", stmt)];
        if words and words[0] in _WRITE_SQL { return True; }
        # a common table expression ahead of the write: `WITH t AS (...) DELETE FROM x`
        if words and words[0] == "WITH" and len([w for w in words if w in ["INSERT", "UPDATE", "DELETE"]]) > 0 { return True; }
    }
    return False;
}

def _scan_mode(n: any, mode: any, target: any, seen: str, memory: list[str], al: dict[str, str], out: dict[str, any]) -> None {
    if mode is None { return; }
    m = _const(mode);
    if m is None {
        _add(out["unknown"], seen + " opens a file with a mode set at run time");
    } elif re.search(r"[wax+]", str(m)) and not _is_memory(target, memory, al) {
        _add(out["writes"], seen);
    }
}

def _is_send(n: any, fname: str, attr: str, clients: list[str]) -> bool {
    if fname in _SENDS or fname.startswith("smtplib.SMTP") { return True; }
    if fname in ["requests.request", "httpx.request"] or (attr == "request" and isinstance(n.func, ast.Attribute)
                                                          and ast.unparse(n.func.value) in clients) {
        method = _const(n.args[0]) if n.args else None;
        return method is None or str(method).upper() not in ["GET", "HEAD", "OPTIONS"];
    }
    if attr in ["post", "put", "patch", "delete"] and isinstance(n.func, ast.Attribute) {
        recv = ast.unparse(n.func.value);
        return recv in clients or re.match(_CLIENT_RE, recv) is not None;
    }
    if fname == "urllib.request.urlopen" or fname == "urllib.request.Request" {
        if _arg(n, 1, ["data"]) is not None { return True; }
        method = _arg(n, -1, ["method"]);
        return method is not None and str(_const(method) or "POST").upper() not in ["GET", "HEAD", "OPTIONS"];
    }
    return False;
}

# --- small AST helpers -----------------------------------------------------

def _aliases(tree: any) -> dict[str, str] {
    # local name -> origin: `import numpy as np` (np -> numpy), `from shutil import copy` (copy -> shutil.copy)
    out: dict[str, str] = {};
    for n in ast.walk(tree) {
        if isinstance(n, ast.Import) {
            for a in n.names { if a.asname { out[a.asname] = a.name; } }
        } elif isinstance(n, ast.ImportFrom) and n.module and not n.level {
            for a in n.names { out[a.asname or a.name] = n.module + "." + a.name; }
        }
    }
    return out;
}

def _dotted(f: any, al: dict[str, str]) -> str {
    if isinstance(f, ast.Name) { return al.get(f.id, f.id); }
    if isinstance(f, ast.Attribute) { return _dotted(f.value, al) + "." + f.attr; }
    return "?";
}

def _memory_names(tree: any, al: dict[str, str]) -> list[str] {
    # names bound only ever to an in-memory file (`buf = io.BytesIO()`, `b = buf`). A name
    # also bound to anything else, a path included, is not one: `buf = "out.txt"`.
    binds: list[any] = [];   # [name, value]; value None: bound by a loop, a parameter, unpacking
    for n in ast.walk(tree) {
        pairs: list[any] = [];
        if isinstance(n, ast.Assign) { pairs = [[t, n.value] for t in n.targets]; }
        elif isinstance(n, (ast.AnnAssign, ast.NamedExpr)) { pairs = [[n.target, n.value]]; }
        elif isinstance(n, ast.AugAssign) { pairs = [[n.target, None]]; }
        elif isinstance(n, ast.withitem) and n.optional_vars is not None { pairs = [[n.optional_vars, n.context_expr]]; }
        elif isinstance(n, (ast.For, ast.comprehension)) { pairs = [[n.target, None]]; }
        elif isinstance(n, ast.arg) { binds.append([n.arg, None]); }
        for (t, v) in pairs {
            if isinstance(t, ast.Name) { binds.append([t.id, v]); continue; }
            for nm in ast.walk(t) { if isinstance(nm, ast.Name) { binds.append([nm.id, None]); } }
        }
    }
    values: dict[str, list[any]] = {};
    for (name, v) in binds { values.setdefault(name, []).append(v); }
    # a name made of buffer calls only can make another one (`b = buf`): grow until stable
    out: list[str] = [];
    grew = True;
    while grew {
        grew = False;
        for (name, vs) in values.items() {
            if name in out { continue; }
            if len([v for v in vs if not (v is not None and _is_memory(v, out, al))]) == 0 {
                out.append(name);
                grew = True;
            }
        }
    }
    return out;
}

def _path_names(tree: any, al: dict[str, str]) -> list[str] {
    # names bound to a pathlib path: `p = Path(x)`, `q = p / "a"`, `for f in d.glob("*")`,
    # and parameters annotated `Path`
    pairs: list[any] = [];
    out: list[str] = [];
    for n in ast.walk(tree) {
        if isinstance(n, ast.Assign) { pairs.append([n.value, list(n.targets)]); }
        elif isinstance(n, (ast.For, ast.comprehension)) and isinstance(n.iter, ast.Call) and isinstance(n.iter.func, ast.Attribute)
             and n.iter.func.attr in ["glob", "rglob", "iterdir"] {
            pairs.append([n.iter.func.value, [n.target]]);
        } elif isinstance(n, ast.arg) and n.annotation is not None and "Path" in ast.unparse(n.annotation) {
            _add(out, n.arg);
        }
    }
    grew = True;
    while grew {
        grew = False;
        for (value, targets) in pairs {
            if not _is_path(value, al, out) { continue; }
            for t in targets {
                for nm in ast.walk(t) {
                    if isinstance(nm, ast.Name) and nm.id not in out { out.append(nm.id); grew = True; }
                }
            }
        }
    }
    return out;
}

def _is_path(e: any, al: dict[str, str], paths: list[str]) -> bool {
    if isinstance(e, ast.Name) { return e.id in paths; }
    if isinstance(e, ast.BinOp) and isinstance(e.op, ast.Div) { return _is_path(e.left, al, paths); }
    if isinstance(e, ast.Attribute) and e.attr in ["parent"] { return _is_path(e.value, al, paths); }
    if isinstance(e, ast.Call) {
        if _dotted(e.func, al) in _PATH_MAKERS { return True; }
        if isinstance(e.func, ast.Attribute) and e.func.attr in _PATH_METHODS { return _is_path(e.func.value, al, paths); }
    }
    return False;
}

def _argv0(n: any) -> str {
    # the program a process call starts, when the code spells it out: `["npm", "run"]`, `"npm run build"`
    if not n.args { return ""; }
    a = n.args[0];
    if isinstance(a, (ast.List, ast.Tuple)) and a.elts { a = a.elts[0]; }
    c = _const(a);
    if c is None or not str(c).strip() { return ""; }
    return str(c).split()[0].split("/")[-1];
}

def _runs_bundled(n: any, py: list[str]) -> bool {
    # an argv list that starts Python on a bundled script: `[sys.executable, "scripts/run.py", x]`,
    # or a path built at run time that ends in a bundled file's name (`str(HERE / "run.py")`).
    # Not `-m` or `-c`, and not an absolute path elsewhere (`/opt/run.py`).
    if not n.args or not isinstance(n.args[0], (ast.List, ast.Tuple)) or len(n.args[0].elts) < 2 { return False; }
    exe = n.args[0].elts[0];
    c = _const(exe);
    if not (ast.unparse(exe) == "sys.executable" or (c is not None and re.match(r"^python[0-9.]*$", str(c).split("/")[-1]) is not None)) {
        return False;
    }
    names = [s.rsplit("/", 1)[-1] for s in py];
    script = n.args[0].elts[1];
    s = _const(script);
    if s is not None { return _bundled(str(s), names); }
    return len([m for m in names if re.search(r"['\"/]" + re.escape(m) + r"['\"]", ast.unparse(script))]) > 0;
}

def _installs(text: str) -> bool {
    # `pip install`, `python -m pip install`, `npm install`, `apt-get install` and the like
    return re.search(r"\b(pip3?|uv pip|npm|apt|apt-get|yarn|pnpm|conda|brew)\b['\",\s]+(install|add|i)\b", text) is not None;
}

def _client_names(tree: any, al: dict[str, str]) -> list[str] {
    # names bound to an HTTP client: `s = requests.Session()`
    out: list[str] = [];
    for n in ast.walk(tree) {
        if isinstance(n, ast.Assign) and isinstance(n.value, ast.Call) and re.match(_CLIENT_RE, _dotted(n.value.func, al)) {
            for t in n.targets { if isinstance(t, ast.Name) { _add(out, t.id); } }
        } elif (isinstance(n, ast.withitem) and isinstance(n.context_expr, ast.Call) and isinstance(n.optional_vars, ast.Name)
                and re.match(_CLIENT_RE, _dotted(n.context_expr.func, al))) {
            _add(out, n.optional_vars.id);
        }
    }
    return out;
}

def _is_memory(e: any, memory: list[str], al: dict[str, str]) -> bool {
    # an in-memory file: the call that makes one (`io.BytesIO()`), or a name bound only to
    # one. Not the words in the code: `open("StringIO.txt", "w")` writes a file.
    if isinstance(e, ast.Name) { return e.id in memory; }
    return isinstance(e, ast.Call) and _dotted(e.func, al) in _MEMORY_CALLS;
}

def _arg(n: any, i: int, kws: list[str]) -> any {
    # positional argument i (-1: keywords only), else the first keyword named in kws
    if i >= 0 and i < len(n.args) and not isinstance(n.args[i], ast.Starred) { return n.args[i]; }
    for k in n.keywords { if k.arg in kws { return k.value; } }
    return None;
}

def _const(e: any) -> any {
    if isinstance(e, ast.Constant) and isinstance(e.value, str) { return e.value; }
    return None;
}

def _short(n: any) -> str {
    return re.sub(r"\s+", " ", ast.unparse(n))[:100];
}
