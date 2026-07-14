# Tests for sigil_observe — annex of sigil_observe.jac (`jac test sigil_observe.jac`).

import os;
import json;

test "read_tail: a missing stream yields an empty list" {
    assert read_tail("/nonexistent/sigil/nope.jsonl") == [];
}

test "read_tail: parses jsonl records and skips blank lines" {
    p = os.path.join(os.getcwd(), ".sigil_obs_test.jsonl");
    with open(p, "w") as f {
        f.write(json.dumps({"model": "a", "prompt_tokens": 1}) + "\n");
        f.write("\n");
        f.write(json.dumps({"model": "b", "prompt_tokens": 2}) + "\n");
    }
    recs = read_tail(p, 10);
    os.remove(p);
    assert len(recs) == 2;
    assert recs[0]["model"] == "a";
    assert recs[1]["prompt_tokens"] == 2;
}
