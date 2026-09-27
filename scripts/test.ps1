<#
.SYNOPSIS
  Smoke test for the iris-agentic-dev Docker image + IRIS connectivity.
.DESCRIPTION
  Verifies: Docker is running, the image pulls, the MCP server starts,
  its tools can be enumerated, IRIS connectivity works, and a harmless
  read-only query succeeds. Fails clearly and stops at the first problem.
#>

param(
    [string]$EnvFile = ".env",
    [string]$Image = $(if ($env:IRIS_MCP_IMAGE) { $env:IRIS_MCP_IMAGE } else { "ghcr.io/intersystems-community/iris-agentic-dev:1.4.2" })
)

$ErrorActionPreference = "Stop"

function Fail($Message) {
    Write-Host "FAIL: $Message" -ForegroundColor Red
    exit 1
}

function Pass($Message) {
    Write-Host "OK: $Message" -ForegroundColor Green
}

# --- Docker Desktop is running -----------------------------------------------
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Fail "Docker CLI not found. Install Docker Desktop: https://www.docker.com/products/docker-desktop/"
}
docker info *> $null
if ($LASTEXITCODE -ne 0) {
    Fail "Docker daemon is not running. Start Docker Desktop and try again."
}

# --- .env exists --------------------------------------------------------------
if (-not (Test-Path $EnvFile)) {
    Fail "$EnvFile not found. Copy .env.example to .env and fill in your IRIS credentials first."
}

function Invoke-Tool([string]$ToolName, [string]$ArgsJson) {
    docker run --rm --env-file $EnvFile $Image tool $ToolName --args $ArgsJson 2>&1
}

Write-Host "==> Pulling $Image"
docker pull $Image *> $null
if ($LASTEXITCODE -ne 0) {
    Fail "Could not pull $Image. Check network access / image name."
}

Write-Host ""
Write-Host "==> [1/4] MCP server starts (check_config)"
$configJson = Invoke-Tool "check_config" "{}"
Write-Host $configJson
if ($LASTEXITCODE -ne 0) {
    Fail "iris-agentic-dev failed to start (exit $LASTEXITCODE)."
}
Pass "MCP server starts."

if ($configJson -match '"write_tools_source":"inferred') {
    Write-Host "WARNING: write_tools_enabled was inferred from the namespace name, not set explicitly. See docs/security.md." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "==> [2/4] MCP client can enumerate IRIS tools"
$toolsJson = docker run --rm --env-file $EnvFile $Image tool --list --json 2>&1
if ($LASTEXITCODE -ne 0) {
    Fail "Could not enumerate tools (exit $LASTEXITCODE): $toolsJson"
}
if ($toolsJson -match '"count":(\d+)') {
    $count = [int]$Matches[1]
} else {
    $count = 0
}
if ($count -le 0) {
    Fail "Tool list was empty or malformed: $toolsJson"
}
Pass "Enumerated $count tools."

Write-Host ""
Write-Host "==> [3/4] IRIS connectivity (iris_namespace_list)"
$nsJson = Invoke-Tool "iris_namespace_list" "{}"
Write-Host $nsJson
if ($LASTEXITCODE -ne 0) {
    Fail "IRIS connection or authentication failed. Check IRIS_HOST/IRIS_WEB_PORT/IRIS_USERNAME/IRIS_PASSWORD in $EnvFile."
}
Pass "Connected to IRIS and listed namespaces."

Write-Host ""
Write-Host "==> [4/4] Read-only query (SELECT CURRENT_TIMESTAMP)"
$queryJson = Invoke-Tool "iris_query" '{"query":"SELECT CURRENT_TIMESTAMP AS NOW"}'
Write-Host $queryJson
if ($LASTEXITCODE -ne 0) {
    Fail "Read-only query failed."
}
Pass "Read-only query succeeded."

Write-Host ""
Write-Host "All smoke tests passed." -ForegroundColor Green
