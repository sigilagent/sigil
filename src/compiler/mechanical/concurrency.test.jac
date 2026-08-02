"""concurrency — the SkillRT Pass-3 analog: ILP stage packing, SPAWN
cross-branch validation, DLP candidates. Pure code, no model."""

def _n(nid: str, ntype: str = "CODE", owner: str = "code", reads: list = [], writes: list = []) -> dict {
    return {"id": nid, "type": ntype, "owner": owner, "reads": list(reads), "writes": list(writes)};
}

def _e(src: str, dst: str) -> dict {
    return {"from": src, "to": dst};
}

test "data-independent chain nodes pack into one stage (ILP)" {
    # a -> b -> c -> d, but b and c both read only what a wrote: b || c
    ir = {
        "nodes": [
            _n("a", writes=["x"]),
            _n("b", reads=["x"], writes=["y"]),
            _n("c", reads=["x"], writes=["z"]),
            _n("d", reads=["y", "z"])
        ],
        "edges": [_e("a", "b"), _e("b", "c"), _e("c", "d")],
        "walker": {"carries": {}},
        "concurrency": {"spawn": "none", "reason": "sequential prose"}
    };
    c = extract_concurrency(ir);
    multi = [s for s in c["stages"] if len(s) >= 2];
    assert len(multi) == 1;
    assert list(multi[0]) == ["b", "c"];
    assert len(c["opportunities"]) == 1;
    assert "b, c" in str(c["opportunities"][0]);
    assert not c["issues"];
}

test "a genuinely sequential chain yields no multi-node stage" {
    ir = {
        "nodes": [
            _n("a", writes=["x"]),
            _n("b", reads=["x"], writes=["y"]),
            _n("c", reads=["y"], writes=["z"])
        ],
        "edges": [_e("a", "b"), _e("b", "c")],
        "walker": {"carries": {}}
    };
    c = extract_concurrency(ir);
    assert not [s for s in c["stages"] if len(s) >= 2];
    assert not c["opportunities"];
}

test "transitive dependency blocks packing across an intermediate" {
    # b writes y; c reads z produced by m which reads y: c transitively needs b
    ir = {
        "nodes": [
            _n("a", writes=["x"]),
            _n("b", reads=["x"], writes=["y"]),
            _n("m", reads=["y"], writes=["z"]),
            _n("c", reads=["z"])
        ],
        "edges": [_e("a", "b"), _e("b", "m"), _e("m", "c")],
        "walker": {"carries": {}}
    };
    c = extract_concurrency(ir);
    assert not [s for s in c["stages"] if len(s) >= 2];
}

test "ROUTE fan-out is exclusive, never a parallel stage" {
    ir = {
        "nodes": [
            _n("a", writes=["x"]),
            _n("r", ntype="ROUTE", reads=["x"]),
            _n("b1", reads=["x"]),
            _n("b2", reads=["x"])
        ],
        "edges": [_e("a", "r"), _e("r", "b1"), _e("r", "b2")],
        "walker": {"carries": {}}
    };
    c = extract_concurrency(ir);
    assert not [s for s in c["stages"] if len(s) >= 2];
}

test "a human gate is a barrier" {
    ir = {
        "nodes": [
            _n("a", writes=["x"]),
            {"id": "g", "type": "GEN-RAW", "owner": "model", "reads": ["x"],
             "writes": ["ans"], "doc": "REQUIRE HUMAN GATE — CONFIRM: proceed?"},
            _n("b", reads=["x"])
        ],
        "edges": [_e("a", "g"), _e("g", "b")],
        "walker": {"carries": {}}
    };
    c = extract_concurrency(ir);
    assert not [s for s in c["stages"] if len(s) >= 2];
}

test "SPAWN branches sharing moving data is a hard G8 issue" {
    ir = {
        "nodes": [
            _n("s", ntype="SPAWN"),
            _n("a1", writes=["shared"]),
            _n("a2", reads=["shared"]),
            _n("j", ntype="TERMINAL")
        ],
        "edges": [_e("s", "a1"), _e("s", "a2"), _e("a1", "j"), _e("a2", "j")],
        "walker": {"carries": {}}
    };
    c = extract_concurrency(ir);
    assert len(c["issues"]) == 1;
    assert "False parallelism" in str(c["issues"][0]);
    assert "shared" in str(c["issues"][0]);
}

test "independent SPAWN branches raise no issue" {
    ir = {
        "nodes": [
            _n("s", ntype="SPAWN"),
            _n("a1", writes=["r1"]),
            _n("a2", writes=["r2"]),
            _n("j", ntype="TERMINAL", reads=["r1", "r2"])
        ],
        "edges": [_e("s", "a1"), _e("s", "a2"), _e("a1", "j"), _e("a2", "j")],
        "walker": {"carries": {}}
    };
    c = extract_concurrency(ir);
    assert not c["issues"];
}

test "a list carry into a tool-backed code node is a DLP candidate" {
    ir = {
        "nodes": [
            _n("gen", ntype="GEN-FILL", owner="model", writes=["frames"]),
            _n("assemble", reads=["frames"], writes=["gif"])
        ],
        "edges": [_e("gen", "assemble")],
        "walker": {"carries": {"frames": {"type": "list[str]", "produced_by": "gen"}}},
        "tools": {"builder": {"body": "return 1", "serves": ["assemble"]}}
    };
    c = extract_concurrency(ir);
    assert len(c["dlp"]) == 1;
    assert "frames" in str(c["dlp"][0]);
}
