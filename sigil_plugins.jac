"""Plugin manifests — OpenClaw parity for bundle plugins.

An OpenClaw plugin is a bundle: skills + MCP servers + config. `plugin_install`
reads an `openclaw.plugin.json` manifest, registers its declared MCP servers and
skills in one shot, and records a `Plugin` node on the graph so `plugin_list`
reflects what's installed. Idempotent by plugin name.

Manifest shape:
    {
      "name": "gh-tools", "version": "1.0.0",
      "mcp_servers": [{"name":"github","transport":"stdio","command":"gh-mcp","args":[]}],
      "skills": [{"path":"./procedure.agir","kind":"agir"}]   // kind: md | agir | osp
    }
"""

import os;
import json;
import from sigil { awaken, Soul, add_mcp, register_skill }

edge Installed {}   # Soul -> Plugin

node Plugin {
    has name: str;
    has version: str = "";
    has skills: list[str] = [];
    has servers: list[str] = [];
}

def _plugins(soul: Soul) -> list[Plugin] { return [soul -->[?:Plugin]]; }

def plugin_install(path: str) -> dict {
    with open(path) as f { manifest = json.loads(f.read()); }
    soul = awaken();
    name = str(manifest.get("name", "plugin"));
    version = str(manifest.get("version", ""));
    base = os.path.dirname(os.path.abspath(path));

    servers: list = [];
    for s in manifest.get("mcp_servers", []) or [] {
        target = str(s.get("command", "") or s.get("url", ""));
        args = [str(a) for a in (s.get("args", []) or [])];
        add_mcp(str(s.get("name", "")), str(s.get("transport", "stdio")), target, args);
        servers.append(str(s.get("name", "")));
    }

    skills: list = [];
    for sk in manifest.get("skills", []) or [] {
        kind = str(sk.get("kind", "md"));
        spath = str(sk.get("path", ""));
        full = spath if os.path.isabs(spath) else os.path.join(base, spath);
        skills.append(spath);
        # agir/osp lift with no model call; md skills are declared here and lifted by
        # the frontier on first `register-skill`/use (kept model-free at install time).
        if (kind in ["agir", "osp"]) and os.path.exists(full) {
            src = full if kind == "osp" else open(full).read();
            try { register_skill(src, kind); } except Exception as e {  }
        }
    }

    for p in _plugins(soul) {
        if p.name == name { p.version = version; p.skills = skills; p.servers = servers; return {"name": name, "updated": True, "servers": servers, "skills": skills}; }
    }
    soul +>:Installed:+> Plugin(name=name, version=version, skills=skills, servers=servers);
    return {"name": name, "updated": False, "servers": servers, "skills": skills};
}

def plugin_list() -> list {
    soul = awaken();
    return [{"name": p.name, "version": p.version, "skills": list(p.skills), "servers": list(p.servers)} for p in _plugins(soul)];
}

def plugin_remove(name: str) -> str {
    soul = awaken();
    for p in _plugins(soul) { if p.name == name { del p; return "removed plugin '" + name + "'"; } }
    return "no such plugin: " + name;
}
