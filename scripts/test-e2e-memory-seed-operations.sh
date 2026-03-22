#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/test-e2e-memory-seed-operations.sh [--skip-build] [--keep-artifacts]

Runs a local end-to-end validation for seeded memory enrichment tables with
operation-based live updates:

  mock REST service -> http_client source -> memory enrichment table -> filter -> console

The script verifies:
1. A live upsert overrides seeded data.
2. A delete restores seeded fallback for seeded keys.
3. A non-seeded upsert remains present.
EOF
}

SKIP_BUILD=0
KEEP_ARTIFACTS=0

while (($#)); do
  case "$1" in
    --skip-build)
      SKIP_BUILD=1
      shift
      ;;
    --keep-artifacts)
      KEEP_ARTIFACTS=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/vector-memory-seed-ops.XXXXXX")"
data_dir="${tmp_dir}/vector-data"
mkdir -p "${data_dir}"

vector_pid=""
server_pid=""

cleanup() {
  if [[ -n "${vector_pid}" ]] && kill -0 "${vector_pid}" 2>/dev/null; then
    kill "${vector_pid}" 2>/dev/null || true
    wait "${vector_pid}" 2>/dev/null || true
  fi
  if [[ -n "${server_pid}" ]] && kill -0 "${server_pid}" 2>/dev/null; then
    kill "${server_pid}" 2>/dev/null || true
    wait "${server_pid}" 2>/dev/null || true
  fi
  if [[ "${KEEP_ARTIFACTS}" -eq 0 ]]; then
    rm -rf "${tmp_dir}"
  else
    echo "Kept artifacts in: ${tmp_dir}"
  fi
}
trap cleanup EXIT

port="$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)"

cat > "${tmp_dir}/mock_service.py" <<'PY'
#!/usr/bin/env python3
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import argparse
import json

OPS = [
    # First scrape: apply overrides.
    [
        {"op": "upsert", "key": "foo", "value": {"rate": 90}},
        {"op": "upsert", "key": "baz", "value": {"rate": 20}},
    ],
    # Second scrape: delete foo so seed fallback is restored.
    [
        {"op": "delete", "key": "foo"},
    ],
]

state = {"calls": 0}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok")
            return

        if self.path != "/updates":
            self.send_response(404)
            self.end_headers()
            return

        idx = state["calls"]
        payload = OPS[idx] if idx < len(OPS) else []
        state["calls"] += 1
        body = ("\n".join(json.dumps(item) for item in payload) + ("\n" if payload else "")).encode("utf-8")

        self.send_response(200)
        self.send_header("Content-Type", "application/x-ndjson")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def log_message(self, format, *args):  # noqa: A003
        return


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
PY
chmod +x "${tmp_dir}/mock_service.py"

cat > "${tmp_dir}/seed.csv" <<'EOF'
key,rate
foo,10
EOF

cat > "${tmp_dir}/vector.toml" <<EOF
data_dir = "${data_dir}"

[sources.rule_updates]
type = "http_client"
endpoint = "http://127.0.0.1:${port}/updates"
scrape_interval_secs = 3
scrape_timeout_secs = 1
framing.method = "newline_delimited"
decoding.codec = "json"

[enrichment_tables.sample_rules]
type = "memory"
inputs = ["rule_updates"]
input_mode = "operations"
ttl = 600
scan_interval = 30

[enrichment_tables.sample_rules.seed]
path = "${tmp_dir}/seed.csv"
key_field = "key"

[enrichment_tables.sample_rules.seed.schema]
rate = "integer"

[enrichment_tables.sample_rules.source_config]
source_key = "sample_rules_source"
export_interval = 1
remove_after_export = false

[transforms.project_rates]
type = "remap"
inputs = ["sample_rules_source"]
source = """
.rate = to_int(.value.rate) ?? -1
. = {"key": .key, "rate": .rate}
"""

[transforms.only_known]
type = "filter"
inputs = ["project_rates"]
condition = '.key == "foo" || .key == "baz"'

[sinks.out]
type = "console"
inputs = ["only_known"]
target = "stdout"
encoding.codec = "json"
EOF

if [[ "${SKIP_BUILD}" -eq 0 ]]; then
  echo "Building Vector binary for local e2e..."
  cargo build \
    --bin vector \
    --no-default-features \
    --features "sources-http_client,transforms-remap,transforms-filter,sinks-console,enrichment-tables-memory"
fi

vector_bin="${repo_root}/target/debug/vector"
if [[ ! -x "${vector_bin}" ]]; then
  echo "Vector binary not found at ${vector_bin}" >&2
  echo "Run without --skip-build or build it manually first." >&2
  exit 1
fi

python3 "${tmp_dir}/mock_service.py" --port "${port}" > "${tmp_dir}/mock_service.log" 2>&1 &
server_pid="$!"

for _ in {1..40}; do
  if curl -fsS "http://127.0.0.1:${port}/health" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

if ! curl -fsS "http://127.0.0.1:${port}/health" >/dev/null 2>&1; then
  echo "Mock service did not start correctly." >&2
  exit 1
fi

echo "Running Vector with e2e config..."
"${vector_bin}" --quiet --config "${tmp_dir}/vector.toml" \
  > "${tmp_dir}/vector.out.log" \
  2> "${tmp_dir}/vector.err.log" &
vector_pid="$!"

sleep 10

if kill -0 "${vector_pid}" 2>/dev/null; then
  kill "${vector_pid}" 2>/dev/null || true
  wait "${vector_pid}" 2>/dev/null || true
fi
vector_pid=""

out_log="${tmp_dir}/vector.out.log"
err_log="${tmp_dir}/vector.err.log"

assert_line_pair() {
  local key="$1"
  local rate="$2"
  if ! rg -q "\"key\":\"${key}\".*\"rate\":${rate}|\"rate\":${rate}.*\"key\":\"${key}\"" "${out_log}"; then
    echo "Assertion failed: expected key=${key} with rate=${rate} in output." >&2
    echo "--- Vector stdout ---" >&2
    tail -n 100 "${out_log}" >&2 || true
    echo "--- Vector stderr ---" >&2
    tail -n 100 "${err_log}" >&2 || true
    exit 1
  fi
}

assert_line_pair "foo" 90
assert_line_pair "foo" 10
assert_line_pair "baz" 20

echo "E2E passed."
echo "Validated behavior:"
echo "  - upsert override observed (foo -> 90)"
echo "  - delete fallback observed (foo -> 10 from seed)"
echo "  - non-seeded upsert observed (baz -> 20)"
echo
echo "Logs:"
echo "  stdout: ${out_log}"
echo "  stderr: ${err_log}"
