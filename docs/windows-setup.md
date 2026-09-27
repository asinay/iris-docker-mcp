# Windows setup (Docker Desktop + MCP Toolkit)

Every command below was run against a real Docker Desktop install (Docker Desktop with
the `docker mcp` CLI plugin) while writing this doc — none of it is guessed from
documentation alone. `docker mcp --help` / `docker mcp <subcommand> --help` is
authoritative for your installed version if anything here drifts.

There are two ways to use `iris-agentic-dev` from Windows. Pick one:

- **[Path A — Docker MCP Toolkit](#path-a--docker-mcp-toolkit)**: register it as a
  catalog entry, group it into a profile, connect a client through the gateway. More
  moving parts, but this is what "Docker Desktop MCP Toolkit integration" means, and it
  gives you Docker's own secret storage and tool-list UI.
- **[Path B — direct `docker run`](#path-b--direct-docker-run-no-toolkit)**: put a
  `docker run` command straight into your MCP client's own config file, the same way
  upstream's own [Windows Docker doc](https://github.com/intersystems-community/iris-agentic-dev/blob/master/docs/windows-docker.md)
  describes. Fewer moving parts, no gateway, works with any MCP client today.

Both run the exact same upstream image. Path A adds Docker's gateway/profile layer on
top; Path B does not.

## Prerequisites

- Docker Desktop for Windows, with the MCP Toolkit CLI available (`docker mcp --help`
  should print a command list — this ships with current Docker Desktop; no separate
  install step was found in Docker's docs beyond having Docker Desktop itself).
- An IRIS instance reachable from Docker Desktop's network — natively on Windows
  (`host.docker.internal`), in another container, or on a remote host.
- This repo cloned locally, with `.env` created from `.env.example` (see
  [README.md](../README.md#configuration)).

## Path A — Docker MCP Toolkit

### 1. Build a local catalog from this repo's `server.yaml`

`docker mcp catalog create --server file://...` requires the file to resolve under
`~/.docker/mcp/catalogs/`, so copy it there first:

```powershell
New-Item -ItemType Directory -Force "$env:USERPROFILE\.docker\mcp\catalogs\iris-docker-mcp" | Out-Null
Copy-Item .\server.yaml "$env:USERPROFILE\.docker\mcp\catalogs\iris-docker-mcp\server.yaml"

docker mcp catalog create iris-mcp-catalog --title "IRIS Agentic Dev" `
  --server file://iris-docker-mcp/server.yaml
```

Verify it resolved correctly:

```powershell
docker mcp catalog show iris-mcp-catalog:latest
```

You should see a `servers:` entry named `iris-agentic-dev` pointing at
`ghcr.io/intersystems-community/iris-agentic-dev:1.4.2` with `IRIS_HOST`, `IRIS_WEB_PORT`,
etc. under `env:` and the password under `secrets:`.

### 2. Create a profile and configure the connection

A profile is the unit Docker's gateway actually runs. Pick a profile name per the
[profiles](../README.md#profiles) you want (`iris-readonly`, `iris-developer`,
`iris-operations`, or `iris-full`):

```powershell
docker mcp profile create --name iris-readonly `
  --server "catalog://iris-mcp-catalog/iris-agentic-dev"
```

This prints the generated profile id (dashes become underscores, e.g. `iris_readonly`).
Set the connection env vars on that profile — the required syntax is
`<serverName>.<configName>=<value>`, where `<serverName>` is `iris-agentic-dev`:

```powershell
docker mcp profile config iris_readonly `
  --set iris-agentic-dev.IRIS_HOST=host.docker.internal `
  --set iris-agentic-dev.IRIS_WEB_PORT=52773 `
  --set iris-agentic-dev.IRIS_NAMESPACE=USER `
  --set iris-agentic-dev.IRIS_WRITE_TOOLS_ENABLED=0 `
  --set iris-agentic-dev.IRIS_DESTRUCTIVE_TOOLS_ENABLED=0
```

Store the password as a Docker secret rather than plain config (see
[docs/security.md](security.md)):

```powershell
echo "your-iris-password" | docker mcp secret set iris-agentic-dev.password
```

Confirm everything landed:

```powershell
docker mcp profile show iris_readonly
```

### 3. Verify the gateway can see the tools

```powershell
docker mcp tools ls --gateway-arg --profile=iris_readonly
```

This should print the full `iris-agentic-dev` tool list (we saw 89 entries, including
Docker's own gateway meta-tools like `mcp-find`/`mcp-exec`) — proof the catalog, profile,
and image are wired together correctly. `docker mcp tools call check_config
--gateway-arg --profile=iris_readonly` should also run without error, though we found
`docker mcp tools call` doesn't reliably thread profile-scoped config into the container
env in this CLI version — if `check_config`'s `host` field comes back empty, that's a
known rough edge of testing through the raw CLI, not of your setup. Use
[scripts/test.ps1](../scripts/test.ps1) (Path B, direct `docker run`) as the authoritative
connectivity check — it exercises the exact same image with explicit env vars and is
what we validated end-to-end.

### 4. Enable it in Docker Desktop and connect a client

Open **Docker Desktop → MCP Toolkit**. Your `iris-mcp-catalog` and the profile you
created should be visible there (Docker Desktop and the CLI share the same underlying
state). From the **Clients** tab, click **Connect** next to your MCP client (Claude
Desktop, VS Code, etc.), or from the CLI:

```powershell
docker mcp client connect claude-code
```

(Supported clients per `docker mcp client --help`: `claude-code`, `claude-desktop`,
`cline`, `codex`, `continue`, `crush`, `cursor`, `gemini`, `goose`, `gordon`, `kiro`,
`lmstudio`, `opencode`, `sema4`, `vscode`, `zed`.)

Restart the client, then ask it to call `check_config` or `iris_namespace_list`.

## Path B — direct `docker run` (no Toolkit)

If you just want `iris-agentic-dev` available in Claude Code without going through the
gateway, add this to `.claude/mcp.json` (project) or `~/.claude/mcp.json` (global) —
this mirrors upstream's own
[windows-docker.md](https://github.com/intersystems-community/iris-agentic-dev/blob/master/docs/windows-docker.md):

```json
{
  "mcpServers": {
    "iris-agentic-dev": {
      "command": "docker",
      "args": [
        "run", "--rm", "-i",
        "--env-file", "C:\\path\\to\\iris-docker-mcp\\.env",
        "ghcr.io/intersystems-community/iris-agentic-dev:1.4.2",
        "mcp"
      ]
    }
  }
}
```

Using `--env-file` instead of a hardcoded `env` block keeps credentials out of the MCP
config file too — only `.env` (gitignored) holds the real values.

## Applying a category profile (`policy.default` TOML)

To use one of `config/profiles/*.toml` (see [docs/security.md](security.md)) with either
path above, mount it into the container and point `OBJECTSCRIPT_WORKSPACE` at the
directory it's mounted in. We confirmed this works with `--verbose` debug logging
(`Loaded fleet config from /work/.iris-agentic-dev.toml`):

```powershell
docker run --rm -i `
  --env-file .env `
  -v "${PWD}\config\profiles\readonly.toml:/work/.iris-agentic-dev.toml:ro" `
  -e OBJECTSCRIPT_WORKSPACE=/work `
  ghcr.io/intersystems-community/iris-agentic-dev:1.4.2 `
  mcp
```

Swap `readonly.toml` for `developer.toml`, `operations.toml`, or `full.toml` to change
profile. For Path B (a client's `mcp.json`), add the `-v` and `-e
OBJECTSCRIPT_WORKSPACE=/work` entries into that config's `args` array the same way.

## Running the smoke test

```powershell
.\scripts\test.ps1
```

See [README.md](../README.md#smoke-test) for what it checks and how it fails.

## Remote or containerized IRIS

- **IRIS on the Windows host**: `IRIS_HOST=host.docker.internal` (default in
  `.env.example`).
- **IRIS in another container**: use that container's name if it's on the same Docker
  network, or `host.docker.internal` if you're only exposing a port to the host.
- **Remote IRIS**: set `IRIS_HOST` to its hostname/IP. No Docker MCP Toolkit or Docker
  documentation mentions anything Windows-specific for this case — standard Docker
  Desktop networking applies.

## Troubleshooting

- **`docker: command not found`** — Docker Desktop isn't installed or isn't on `PATH`.
- **`docker mcp: command not found`** — your Docker Desktop version predates the MCP
  Toolkit CLI plugin; update Docker Desktop.
- **Docker daemon not running** — start Docker Desktop and wait for it to report
  "Engine running" before retrying.
- **`local file path must resolve within Docker MCP catalogs directory`** — you tried
  `--server file://./server.yaml` directly; copy the file under
  `~/.docker/mcp/catalogs/` first (step 1 above).
- **Connection refused / `HTTP error` calling any IRIS tool** — IRIS isn't reachable at
  `IRIS_HOST:IRIS_WEB_PORT`. Confirm the Atelier REST API answers directly:
  `curl http://host.docker.internal:52773/api/atelier/` from the same machine running
  Docker Desktop.
- **IIS on Windows, 404 from every tool** — see the "Windows IIS: `/api` web
  application required" section in upstream's
  [docs/connecting.md](https://github.com/intersystems-community/iris-agentic-dev/blob/master/docs/connecting.md).
