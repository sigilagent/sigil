# Tests for sigil_secrets — annex of sigil_secrets.jac (`jac test sigil_secrets.jac`).
# Covers the console's secrets file. Each test points SIGIL_HOME at a fresh temp
# dir and puts the environment back, so no real key is read or written.

import os;
import stat;
import tempfile;

def _isolated(names: list[str]) -> dict[str, str | None] {
    saved: dict[str, str | None] = {"SIGIL_HOME": os.environ.get("SIGIL_HOME")};
    for n in names { saved[n] = os.environ.get(n); os.environ.pop(n, None); }
    os.environ["SIGIL_HOME"] = tempfile.mkdtemp();
    return saved;
}

def _restore(saved: dict[str, str | None]) {
    for (k, v) in saved.items() {
        if v is None { os.environ.pop(k, None); } else { os.environ[k] = v; }
    }
}

test "a saved key lands in a 0600 file and in this process's environment" {
    saved = _isolated(["_T_SIGIL_KEY_A"]);
    r = secret_value_set("_T_SIGIL_KEY_A", "  sk-test-1234567890abcd  ");
    assert r["ok"], str(r);
    path = secrets_env_path();
    assert os.path.exists(path);
    assert stat.S_IMODE(os.stat(path).st_mode) == 0o600, oct(os.stat(path).st_mode);
    assert read_secret_env()["_T_SIGIL_KEY_A"] == "sk-test-1234567890abcd", "the value is stored trimmed";
    assert os.environ["_T_SIGIL_KEY_A"] == "sk-test-1234567890abcd";
    assert secret_source("_T_SIGIL_KEY_A") == "console";
    assert secret_tail("_T_SIGIL_KEY_A") == "abcd";
    _restore(saved);
}

test "a variable exported in the shell wins over the file" {
    saved = _isolated(["_T_SIGIL_KEY_B"]);
    secret_value_set("_T_SIGIL_KEY_B", "from-the-console-file");
    os.environ["_T_SIGIL_KEY_B"] = "from-the-shell";
    assert load_secret_env() == 0, "a set variable is never replaced";
    assert os.environ["_T_SIGIL_KEY_B"] == "from-the-shell";
    assert secret_source("_T_SIGIL_KEY_B") == "shell";
    # clearing the console's copy leaves the shell's value alone
    assert secret_value_clear("_T_SIGIL_KEY_B")["removed"];
    assert os.environ["_T_SIGIL_KEY_B"] == "from-the-shell";
    # and a fresh process with the variable unset picks the file's value up
    secret_value_set("_T_SIGIL_KEY_B", "from-the-console-file");
    os.environ.pop("_T_SIGIL_KEY_B", None);
    assert load_secret_env() >= 1;
    assert os.environ["_T_SIGIL_KEY_B"] == "from-the-console-file";
    _restore(saved);
}

test "bad names, empty values and line breaks are refused" {
    saved = _isolated([]);
    assert not secret_value_set("1BAD", "x")["ok"];
    assert not secret_value_set("HAS-DASH", "x")["ok"];
    assert not secret_value_set("", "x")["ok"];
    assert not secret_value_set("_T_SIGIL_OK", "   ")["ok"];
    assert not secret_value_set("_T_SIGIL_OK", "a" + chr(10) + "_T_INJECTED=1")["ok"];
    assert not os.path.exists(secrets_env_path()), "nothing was written";
    assert env_name_ok("BRAVE_API_KEY") and env_name_ok("_x1");
    assert secret_tail("_T_SIGIL_UNSET") == "";
    _restore(saved);
}
