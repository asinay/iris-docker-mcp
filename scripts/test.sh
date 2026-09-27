#!/usr/bin/env bash
# Smoke test for the iris-agentic-dev Docker image + IRIS connectivity.
# See scripts/test.ps1 for the Windows PowerShell equivalent.
set -uo pipefail

IMAGE="${IRIS_MCP_IMAGE:-ghcr.io/intersystems-community/iris-agentic-dev:1.4.2}"
ENV_FILE="${1:-.env}"

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "OK: $1"; }

command -v docker >/dev/null 2>&1 || fail "Docker CLI not found. Install Docker Desktop and reopen your shell."
docker info >/dev/null 2>&1 || fail "Docker daemon is not running. Start Docker Desktop."
[ -f "$ENV_FILE" ] || fail "$ENV_FILE not found. Copy .env.example to .env and fill in your IRIS credentials first."

echo "==> Pulling $IMAGE"
docker pull "$IMAGE" >/dev/null 2>&1 || fail "Could not pull $IMAGE. Check network access / image name."

run_tool() {
  docker run --rm --env-file "$ENV_FILE" "$IMAGE" tool "$1" --args "$2"
}

echo ""
echo "==> [1/4] MCP server starts (check_config)"
CONFIG_JSON=$(run_tool check_config '{}' 2>&1)
STATUS=$?
echo "$CONFIG_JSON"
[ $STATUS -eq 0 ] || fail "iris-agentic-dev failed to start (exit $STATUS)."
pass "MCP server starts."

if echo "$CONFIG_JSON" | grep -q '"write_tools_source":"inferred'; then
  echo "WARNING: write_tools_enabled was inferred from the namespace name, not set explicitly. See docs/security.md."
fi

echo ""
echo "==> [2/4] MCP client can enumerate IRIS tools"
TOOLS_JSON=$(docker run --rm --env-file "$ENV_FILE" "$IMAGE" tool --list --json 2>&1)
STATUS=$?
[ $STATUS -eq 0 ] || fail "Could not enumerate tools (exit $STATUS): $TOOLS_JSON"
COUNT=$(echo "$TOOLS_JSON" | grep -o '"count":[0-9]*' | head -1 | cut -d: -f2)
[ -n "$COUNT" ] && [ "$COUNT" -gt 0 ] || fail "Tool list was empty or malformed: $TOOLS_JSON"
pass "Enumerated $COUNT tools."

echo ""
echo "==> [3/4] IRIS connectivity (iris_namespace_list)"
NS_JSON=$(run_tool iris_namespace_list '{}' 2>&1)
STATUS=$?
echo "$NS_JSON"
[ $STATUS -eq 0 ] || fail "IRIS connection or authentication failed. Check IRIS_HOST/IRIS_WEB_PORT/IRIS_USERNAME/IRIS_PASSWORD in $ENV_FILE."
pass "Connected to IRIS and listed namespaces."

echo ""
echo "==> [4/4] Read-only query (SELECT CURRENT_TIMESTAMP)"
Q_JSON=$(run_tool iris_query '{"query":"SELECT CURRENT_TIMESTAMP AS NOW"}' 2>&1)
STATUS=$?
echo "$Q_JSON"
[ $STATUS -eq 0 ] || fail "Read-only query failed."
pass "Read-only query succeeded."

echo ""
echo "All smoke tests passed."
