"""Reading an AG-IR document — the one place that decides what "parses".

The AG-IR is authored YAML, and authored YAML is not always strict YAML. Three
things routinely arrive that `yaml.safe_load` rejects outright:

  · a markdown code fence, because chat models fence YAML by default;
  · a flow map with unquoted values — `{ type: list[str], role: input }` — where
    the `[` opens a flow sequence YAML never sees closed;
  · a plain scalar carrying its own colon, e.g. `doc: Title : <title>`, which
    reads as an illegal nested mapping.

Each of those used to crash a whole compile to an empty module, so the mechanical
back-end grew a relaxer and a second-chance quoter. They live HERE rather than in
the compiler because the Observatory reads the same documents to draw them: a
viewer that parsed differently from the compiler would render a graph the compiler
never built, and the disagreement would show up as "the UI is wrong" rather than
as the drift it is.

This module is a leaf — `re` and `yaml`, nothing of Sigil's. That is what lets the
compiler and the runtime both import it without either importing the other.
"""

import re;
import yaml;

def _j(sep: str, items: any) -> str {
    return sep.join([str(x) for x in items]);
}

def _relax_line(line: str) -> str {
    # An inline flow map whose values are bare words -> the same map, quoted.
    ln = re.sub(r"(\S):\{", r"\1: {", line);
    m: any = re.match(r"^(\s*[\w\".\-]+\s*):\s*\{(.*)\}\s*$", ln);
    if not m { return ln; }
    head = str(m.group(1));
    inner = str(m.group(2));
    # Already-valid flow maps (quoted values, nested braces) must be left alone.
    try { yaml.safe_load("{" + inner + "}"); return ln; }
    except Exception {  }
    parts: any = re.split(r",(?=\s*[\w\"]+\s*:)", inner);
    fixed: list = [];
    for p in parts {
        if ":" not in p { fixed.append(p.strip()); continue; }
        kv: any = p.partition(":");
        k = str(kv[0]).strip();
        v = str(kv[2]).strip();
        if v and (v[0] not in "\"'[{") { v = "'" + v.replace("'", "''") + "'"; }
        fixed.append(f"{k}: {v}");
    }
    joined = _j(", ", fixed);
    return f"{head}: {{ {joined} }}";
}

def relax(text: str) -> str {
    return _j("\n", [_relax_line(l) for l in text.splitlines()]);
}

# Second-chance relaxer, run ONLY after yaml.safe_load has already failed: the
# usual culprit is a PLAIN-scalar value that itself contains a colon — a lifted
# format/doc line like `doc: Title : <title>`, which YAML reads as an illegal
# nested mapping ("mapping values are not allowed here") and which otherwise
# crashes the whole compile to an empty module. Quote such values and let the
# caller retry. Because it fires only on failure, VALID IR is never reshaped.
# Block-scalar bodies (`key: |` / `key: >`) are left untouched — their colons are
# already legal YAML, and they only reach here when some OTHER line broke first.
def quote_colon_scalars(text: str) -> str {
    out: list = [];
    block_indent: int = -1;   # indent of an open `key: |`/`>` block, else -1
    for line in text.splitlines() {
        stripped = line.lstrip();
        indent = len(line) - len(stripped);
        if block_indent >= 0 {
            # a blank line or a deeper-indented line is block-scalar content
            if (stripped == "") or (indent > block_indent) { out.append(line); continue; }
            block_indent = -1;   # dedented back out of the block scalar
        }
        # a key that OPENS a block scalar: `key: |`, `- key: >-`, `key: |2`, …
        mb: any = re.match(r"^(\s*)(?:-\s+)?[\w\"'.\-]+:\s*[|>][0-9+-]*\s*$", line);
        if mb { block_indent = len(str(mb.group(1))); out.append(line); continue; }
        # a mapping line `key: value` (incl. list item `- key: value`)
        mm: any = re.match(r"^(\s*(?:-\s+)?[\w\"'.\-]+):[ \t]+(\S.*?)[ \t]*$", line);
        if not mm { out.append(line); continue; }
        head = str(mm.group(1));
        val = str(mm.group(2));
        # already safe: quoted / flow map|seq / anchor|alias|tag, or no inner
        # colon that YAML would misread (a colon must be followed by space/eol)
        if (val[0] in "\"'[{&*!") or (not re.search(r":(?:\s|$)", val)) { out.append(line); continue; }
        out.append(head + ": '" + val.replace("'", "''") + "'");
    }
    return _j("\n", out);
}

def split_document(text: str) -> list {
    # -> [frontmatter_text, body_text]. Strips a markdown fence, then splits the
    # `--- … ---` frontmatter the authored form carries above the contract.
    s = str(text or "").strip();
    if s.startswith("```") {
        nl = s.find("\n");
        s = s[nl + 1:] if nl != -1 else "";
        c = s.rstrip();
        if c.endswith("```") { s = c[:c.rfind("```")]; }
    }
    if s.lstrip().startswith("---") {
        t = s.lstrip();
        end = t.find("\n---", 3);
        if end != -1 { return [t[3:end], t[end + 4:]]; }
    }
    return ["", s];
}

def load_agir(text: str) -> dict {
    # An AG-IR document -> its mapping, with `_frontmatter` attached. Never
    # raises: an undecodable document is an empty mapping, and the caller
    # decides what to say about it.
    parts = split_document(text);
    fm: any = {};
    if str(parts[0]).strip() {
        try { fm = yaml.safe_load(str(parts[0])) or {}; }
        except Exception { fm = {}; }
    }
    relaxed = relax(str(parts[1]));
    ir: any = {};
    try { ir = yaml.safe_load(relaxed) or {}; }
    except Exception {
        # a colon-bearing plain scalar is the common break — quote and retry once
        try { ir = yaml.safe_load(quote_colon_scalars(relaxed)) or {}; }
        except Exception { ir = {}; }
    }
    if not isinstance(ir, dict) { ir = {}; }
    if "_frontmatter" not in ir { ir["_frontmatter"] = fm; }
    return ir;
}


# ---------------------------------------------------------------------------
# Writing an AG-IR document — the inverse of load_agir.
#
# Four modules grew the same parse -> mutate -> re-serialize idiom independently
# (autofix._dump_ir, gates.autofix_carry_types, faith.fold_untraced_prohibitions,
# assemble), so the frontmatter split-and-rejoin was written four times and could
# drift four ways. It belongs next to the reader that defines what "parses".
#
# The block-scalar presenter is not cosmetic. A tool body round-trips through
# yaml.safe_dump as one escaped line ("def f(x):\n    return x\n"), and the AG-IR
# is the artifact a human reads when a compile goes wrong — the provenance the
# TaskGraph persists. Emitting multi-line strings as `|` blocks keeps an IR that
# survived a pass looking like the IR the author wrote.
# ---------------------------------------------------------------------------

class _BlockDumper(yaml.SafeDumper) {}

def _block_str(dumper: any, data: any) -> any {
    # Multi-line -> literal block. PyYAML falls back to a quoted style on its own
    # when the scalar cannot be a block (trailing spaces on a line, stray \r), so
    # asking for '|' is safe rather than a correctness gamble.
    s = str(data);
    if ("\n" in s) and ("\r" not in s) {
        return dumper.represent_scalar("tag:yaml.org,2002:str", s, style="|");
    }
    return dumper.represent_scalar("tag:yaml.org,2002:str", s);
}

with entry {
    # Registered on the subclass, never on yaml.SafeDumper itself: a global
    # representer would silently change every other safe_dump in the process.
    yaml.add_representer(str, _block_str, Dumper=_BlockDumper);
}

def dump_agir(ir: any, block_scalars: bool = True) -> str {
    # An AG-IR mapping -> its document text, `_frontmatter` re-emitted as the
    # `--- … ---` prelude the authored form carries. sort_keys=False is
    # load-bearing: key order IS the pipeline order the back-end lowers.
    if not isinstance(ir, dict) { return ""; }
    dumper = _BlockDumper if block_scalars else yaml.SafeDumper;
    fm = ir.get("_frontmatter") if isinstance(ir.get("_frontmatter"), dict) else {};
    body: dict = {};
    for k in ir {
        if str(k) != "_frontmatter" { body[k] = ir[k]; }
    }
    out = str(yaml.dump(body, Dumper=dumper, sort_keys=False, allow_unicode=True, default_flow_style=False));
    if fm {
        out = ("---\n"
               + str(yaml.dump(fm, Dumper=dumper, sort_keys=False, allow_unicode=True, default_flow_style=False))
               + "---\n" + out);
    }
    return out;
}

def strict_parses(text: str) -> bool {
    # Does the BODY of this document parse as strict YAML, with no relaxation?
    # The relaxer exists because authored YAML often does not — this is how a
    # caller finds out whether it is leaning on that safety net.
    parts = split_document(str(text or ""));
    try {
        yaml.safe_load(str(parts[1]));
        return True;
    } except Exception { return False; }
}
