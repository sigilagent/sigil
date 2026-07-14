"""Typed view-models shared by the server walkers and the browser app.

Walkers report these (not raw dicts) so the client gets typed objects across the
HTTP boundary — the jac-client way (cf. agir-playground's GNode/GEdge).
"""

obj VNode {
    has id: str = "";
    has label: str = "";
    has group: str = "";
    has detail: str = "";
}

obj VEdge {
    has src: str = "";
    has dst: str = "";
    has kind: str = "";
}

obj VGraph {
    has nodes: list[VNode] = [];
    has edges: list[VEdge] = [];
    has skills: int = 0;
    has memories: int = 0;
    has mcp: int = 0;
}

obj VCall {
    has model: str = "";
    has signature: str = "";
    has prompt_tokens: int = 0;
    has completion_tokens: int = 0;
    has reasoning_tokens: int = 0;
    has cache_read_tokens: int = 0;
    has cost_usd: float = 0.0;
    has content: str = "";
    has reasoning: str = "";
    has tools: str = "";
}

obj VObs {
    has calls: list[VCall] = [];
    has tin: int = 0;
    has tout: int = 0;
    has treason: int = 0;
    has cost: float = 0.0;
    has n: int = 0;
}
