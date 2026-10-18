#!/bin/bash
# ccswitch-lite acceptance test. Runs entirely inside a throwaway HOME, so the
# real ~/.claude and ~/.codex are never touched.
set -euo pipefail

# Usage: BIN=/path/to/ccswitch-lite ./tests/test.sh
# Requires: bash, python3 (3.11+ for tomllib), curl, sha256sum.
BIN=${BIN:-$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)/ccswitch-lite}
BASE=${BASE:-/tmp/ccswitch-test}
export BASE
rm -rf "$BASE"
export HOME="$BASE/home"
export XDG_CONFIG_HOME="$HOME/.config"
mkdir -p "$HOME/.config/Claude" "$HOME/.config/Claude-3p/configLibrary" "$HOME/.claude" "$HOME/.codex"

cat > "$HOME/.config/Claude/claude_desktop_config.json" <<'EOF'
{
  "preferences": {"keep": true, "coworkWebSearchEnabled": true},
  "deploymentMode": "1p"
}
EOF
cat > "$HOME/.config/Claude-3p/claude_desktop_config.json" <<'EOF'
{"deploymentMode": "1p", "other": "keep-me"}
EOF
cat > "$HOME/.config/Claude-3p/configLibrary/_meta.json" <<'EOF'
{"entries": [{"id": "other-1", "name": "Other"}], "appliedId": "other-1", "version": 3}
EOF
cat > "$HOME/.claude/settings.json" <<'EOF'
{"permissions": {"allow": ["Bash(ls)"]}, "env": {"KEEP_ME": "1", "ANTHROPIC_BASE_URL": "https://old.example"}}
EOF
cat > "$HOME/.codex/config.toml" <<'EOF'
model = "gpt-5"
approval_policy = "on-request"

[projects."/tmp/x"]
trust_level = "trusted"

[mcp_servers.foo]
command = "foo-server"
args = [
  "--one",
  "--two",
]

[[plugins]]
name = "one"

[[plugins]]
name = "two"
EOF

echo "== add =="
"$BIN" add --name fake --base-url http://127.0.0.1:18080/v1 --api-key test-key \
  --format anthropic --default-model claude-sonnet-4-6 \
  --sonnet claude-sonnet-4-6 --opus claude-opus-4-1 \
  --haiku claude-haiku-4-5 --fable claude-fable-5 \
  --header "X-Test=abc"

echo "== list (key must be masked) =="
LIST=$("$BIN" list)
echo "$LIST"
if grep -q 'test-key' <<<"$LIST"; then echo "FAIL: list leaked the API key"; exit 1; fi
grep -q '^\* .*fake' <<<"$LIST" || { echo "FAIL: current marker missing"; exit 1; }

echo "== apply =="
"$BIN" apply

echo "== apply again (idempotency) =="
"$BIN" apply

export HOME XDG_CONFIG_HOME
python3 - <<'PY'
import glob, json, os, sys

home = os.environ["HOME"]
cfg = os.path.join(home, ".config")
fails = []
def check(cond, msg):
    print(("PASS " if cond else "FAIL ") + msg)
    if not cond:
        fails.append(msg)

def load(p):
    with open(p, encoding="utf-8") as f:
        return json.load(f)

d1 = load(os.path.join(cfg, "Claude/claude_desktop_config.json"))
d2 = load(os.path.join(cfg, "Claude-3p/claude_desktop_config.json"))
check(d1.get("deploymentMode") == "3p", "Claude deploymentMode=3p")
check(d2.get("deploymentMode") == "3p", "Claude-3p deploymentMode=3p")
check(d1.get("preferences", {}).get("keep") is True, "Claude preferences preserved")
check(d2.get("other") == "keep-me", "Claude-3p other field preserved")

prof_path = os.path.join(cfg, "Claude-3p/configLibrary/00000000-0000-4000-8000-000000157210.json")
prof = load(prof_path)
check(prof.get("coworkEgressAllowedHosts") == ["*"], "profile egress hosts")
check(prof.get("disableDeploymentModeChooser") is True, "profile chooser disabled")
check(prof.get("inferenceGatewayApiKey") == "test-key", "profile api key")
check(prof.get("inferenceGatewayAuthScheme") == "bearer", "profile auth scheme")
check(prof.get("inferenceGatewayBaseUrl") == "http://127.0.0.1:18080/v1", "profile base url")
check(prof.get("inferenceProvider") == "gateway", "profile provider=gateway")
names = [m["name"] if isinstance(m, dict) else m for m in prof.get("inferenceModels", [])]
check(names == ["claude-sonnet-4-6", "claude-opus-4-1", "claude-haiku-4-5", "claude-fable-5"],
      "profile inferenceModels: " + repr(names))

meta = load(os.path.join(cfg, "Claude-3p/configLibrary/_meta.json"))
ids = [e.get("id") for e in meta.get("entries", [])]
check("00000000-0000-4000-8000-000000157210" in ids, "meta entry added")
check("other-1" in ids, "meta other entry preserved")
check(meta.get("appliedId") == "00000000-0000-4000-8000-000000157210", "meta appliedId set")
check(meta.get("version") == 3, "meta extra field preserved")

st = load(os.path.join(home, ".claude/settings.json"))
env = st.get("env", {})
check(st.get("permissions", {}).get("allow") == ["Bash(ls)"], "claude settings permissions preserved")
check(env.get("ANTHROPIC_BASE_URL") == "http://127.0.0.1:18080/v1", "claude env base url")
check(env.get("ANTHROPIC_AUTH_TOKEN") == "test-key", "claude env auth token")
check(env.get("ANTHROPIC_MODEL") == "claude-sonnet-4-6", "claude env default model")
check(env.get("ANTHROPIC_DEFAULT_SONNET_MODEL") == "claude-sonnet-4-6", "claude env sonnet")
check(env.get("ANTHROPIC_DEFAULT_OPUS_MODEL") == "claude-opus-4-1", "claude env opus")
check(env.get("ANTHROPIC_DEFAULT_HAIKU_MODEL") == "claude-haiku-4-5", "claude env haiku")
check(env.get("ANTHROPIC_DEFAULT_FABLE_MODEL") == "claude-fable-5", "claude env fable")
check(env.get("KEEP_ME") == "1", "claude env unrelated key preserved")

import tomllib
with open(os.path.join(home, ".codex/config.toml"), "rb") as f:
    toml_text = f.read().decode()
    codex = tomllib.loads(toml_text)
check(codex.get("model_provider") == "ccswitch-fake", "codex model_provider")
check(codex.get("model") == "gpt-5", "codex top-level model preserved")
check(codex.get("approval_policy") == "on-request", "codex approval_policy preserved")
check(codex.get("projects", {}).get("/tmp/x", {}).get("trust_level") == "trusted", "codex projects preserved")
check(codex.get("mcp_servers", {}).get("foo", {}).get("args") == ["--one", "--two"], "codex mcp args preserved")
check(codex.get("plugins") == [{"name": "one"}, {"name": "two"}], "codex array-of-tables preserved")
prov = codex.get("model_providers", {}).get("ccswitch-fake", {})
check(prov.get("name") == "fake", "codex provider name")
check(prov.get("base_url") == "http://127.0.0.1:18080/v1", "codex provider base_url")
check(prov.get("env_key") == "OPENAI_API_KEY", "codex provider env_key")
check(prov.get("wire_api") == "responses", "codex provider wire_api")
check(prov.get("http_headers", {}).get("X-Test") == "abc", "codex extra headers")
check(toml_text.count("[model_providers.ccswitch-fake]") == 1, "codex table not duplicated after second apply")

auth = load(os.path.join(home, ".codex/auth.json"))
check(auth.get("OPENAI_API_KEY") == "test-key", "codex auth.json key written when absent")

baks = []
for root, dirs, files in os.walk(home):
    for name in files:
        if ".bak." in name:
            baks.append(os.path.join(root, name))
check(len(baks) >= 8, "backups created: %d" % len(baks))
for p in baks:
    check(os.path.getsize(p) > 0, "backup non-empty: " + p)

if fails:
    print("\n%d FAILURES" % len(fails))
    sys.exit(1)
print("\nALL CONFIG ASSERTIONS PASSED")
PY

echo "== web UI =="
"$BIN" web --addr 127.0.0.1:18081 >"$BASE/web.log" 2>&1 &
WEB_PID=$!
cleanup() { kill "$WEB_PID" 2>/dev/null || true; }
trap cleanup EXIT
for i in $(seq 1 40); do
  code=$(curl -s -o "$BASE/index.html" -w '%{http_code}' http://127.0.0.1:18081/ || true)
  [ "$code" = "200" ] && break
  sleep 0.25
done
echo "index HTTP $code"
[ "$code" = "200" ] || { echo "FAIL: web index not 200"; exit 1; }
grep -q 'ccswitch-lite' "$BASE/index.html" || { echo "FAIL: index html content"; exit 1; }
STATE=$(curl -s http://127.0.0.1:18081/api/state)
echo "$STATE" | python3 -c 'import json,sys; s=json.load(sys.stdin); assert s["current"]=="fake"; p=s["providers"][0]; assert p["hasKey"] and "test-key" not in json.dumps(s); print("state maskedKey:", p["maskedKey"])'
curl -s -X POST -H 'Content-Type: application/json' -d '{"name":"fake"}' http://127.0.0.1:18081/api/use | tee "$BASE/web-use.json"
python3 -c 'import json,os; j=json.load(open(os.path.join(os.environ["BASE"], "web-use.json"))); assert j["ok"], j'
cleanup
trap - EXIT
echo "WEB TESTS PASSED"

echo "== restore =="
"$BIN" restore
python3 - <<'PY'
import json, os, sys, tomllib
home = os.environ["HOME"]; cfg = os.path.join(home, ".config")
fails = []
def check(c, m):
    print(("PASS " if c else "FAIL ") + m)
    if not c: fails.append(m)
def load(p):
    with open(p, encoding="utf-8") as f: return json.load(f)

d1 = load(os.path.join(cfg, "Claude/claude_desktop_config.json"))
d2 = load(os.path.join(cfg, "Claude-3p/claude_desktop_config.json"))
check(d1.get("deploymentMode") == "1p", "restore Claude 1p")
check(d2.get("deploymentMode") == "1p", "restore Claude-3p 1p")
check(d1.get("preferences", {}).get("keep") is True, "restore keeps preferences")
meta = load(os.path.join(cfg, "Claude-3p/configLibrary/_meta.json"))
ids = [e.get("id") for e in meta.get("entries", [])]
check("00000000-0000-4000-8000-000000157210" not in ids, "restore removes profile entry")
check("other-1" in ids, "restore keeps other entry")
check(meta.get("appliedId") == "other-1", "restore appliedId falls back to other-1")

st = load(os.path.join(home, ".claude/settings.json"))
env = st.get("env", {})
for k in ["ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_MODEL",
          "ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL",
          "ANTHROPIC_DEFAULT_HAIKU_MODEL", "ANTHROPIC_DEFAULT_FABLE_MODEL"]:
    check(k not in env, "restore removes " + k)
check(env.get("KEEP_ME") == "1", "restore keeps unrelated env")

with open(os.path.join(home, ".codex/config.toml"), "rb") as f:
    text = f.read().decode(); codex = tomllib.loads(text)
check("model_provider" not in codex, "restore removes model_provider")
check("ccswitch-fake" not in codex.get("model_providers", {}), "restore removes provider table")
check(codex.get("model") == "gpt-5", "restore keeps codex model")
check(codex.get("projects", {}).get("/tmp/x", {}).get("trust_level") == "trusted", "restore keeps codex projects")
auth = load(os.path.join(home, ".codex/auth.json"))
check("OPENAI_API_KEY" not in auth, "restore removes auth key we wrote")
if fails: sys.exit(1)
print("\nALL RESTORE ASSERTIONS PASSED")
PY

echo "== switch providers =="
"$BIN" add --name fake2 --base-url http://127.0.0.1:18081/v1 --api-key key-two \
  --sonnet claude-sonnet-4-6
"$BIN" use fake2
python3 - <<'PY'
import json, os, sys, tomllib
home = os.environ["HOME"]
with open(os.path.join(home, ".codex/config.toml"), "rb") as f:
    codex = tomllib.loads(f.read().decode())
fails = []
def check(c, m):
    print(("PASS " if c else "FAIL ") + m)
    if not c: fails.append(m)
provs = codex.get("model_providers", {})
cc = [k for k in provs if k.startswith("ccswitch-")]
check(codex.get("model_provider") == "ccswitch-fake2", "switch: model_provider updated")
check(cc == ["ccswitch-fake2"], "switch: stale ccswitch tables removed: " + repr(cc))
auth = json.load(open(os.path.join(home, ".codex/auth.json")))
check(auth.get("OPENAI_API_KEY") == "key-two", "switch: owned auth key updated")
st = json.load(open(os.path.join(home, ".claude/settings.json")))
check(st["env"]["ANTHROPIC_BASE_URL"] == "http://127.0.0.1:18081/v1", "switch: claude env updated")
if fails: sys.exit(1)
print("SWITCH ASSERTIONS PASSED")
PY
"$BIN" restore >/dev/null
python3 - <<'PY'
import json, os, sys, tomllib
home = os.environ["HOME"]
with open(os.path.join(home, ".codex/config.toml"), "rb") as f:
    codex = tomllib.loads(f.read().decode())
fails = []
def check(c, m):
    print(("PASS " if c else "FAIL ") + m)
    if not c: fails.append(m)
cc = [k for k in codex.get("model_providers", {}) if k.startswith("ccswitch-")]
check(cc == [], "final restore: no ccswitch tables")
check("model_provider" not in codex, "final restore: model_provider removed")
auth = json.load(open(os.path.join(home, ".codex/auth.json")))
check("OPENAI_API_KEY" not in auth, "final restore: owned auth key removed")
if fails: sys.exit(1)
print("FINAL RESTORE ASSERTIONS PASSED")
PY

echo "== malformed input safety =="
export HOME="$BASE/home2"; export XDG_CONFIG_HOME="$HOME/.config"
mkdir -p "$HOME/.claude" "$HOME/.codex"
printf '{ this is not json\n' > "$HOME/.claude/settings.json"
before=$(sha256sum "$HOME/.claude/settings.json" | cut -d' ' -f1)
"$BIN" add --name fake2 --base-url http://127.0.0.1:18080/v1 --api-key k2 >/dev/null
if "$BIN" apply; then echo "FAIL: apply should refuse invalid JSON"; exit 1; fi
after=$(sha256sum "$HOME/.claude/settings.json" | cut -d' ' -f1)
[ "$before" = "$after" ] || { echo "FAIL: invalid settings.json was modified"; exit 1; }
echo "PASS: invalid JSON refused, original file untouched"

echo "ALL TESTS PASSED"
