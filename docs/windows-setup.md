# Windows setup (Docker Desktop + MCP Toolkit)

Every command below was run against a real Docker Desktop install (Docker Desktop with
the `docker mcp` CLI plugin) while writing this doc — none of it is guessed from
documentation alone. `docker mcp --help` / `docker mcp <subcommand> --help` is
authoritative for your installed version if anything here drifts.

There are two ways to use `iris-agentic-dev` from Windows:

- **[Path A — Docker MCP Toolkit](#path-a--docker-mcp-toolkit)**: register it as a
  catalog entry, group it into a profile, connect a client through the gateway. This is
  what "Docker Desktop MCP Toolkit integration" means, and it gives you Docker's own
  secret storage and tool-list UI.
- **[Path B — direct `docker run`](#path-b--direct-docker-run-no-toolkit)**: put a
  `docker run` command straight into your MCP client's own config file, the same way
  upstream's own [Windows Docker doc](https://github.com/intersystems-community/iris-agentic-dev/blob/master/docs/windows-docker.md)
  describes. Fewer moving parts, no gateway.

Both run the exact same upstream image. Both are verified working end-to-end against a
real IRIS instance.

> ### A schema bug we found and fixed: plain env vars weren't reaching the container
>
> Earlier testing hit a real failure: a profile's env var config (`IRIS_HOST` etc.) was
> stored correctly by `docker mcp profile config` — `docker mcp profile show` listed it
> right — but never reached the container, so every tool call failed with
> `IRIS_UNREACHABLE` and `check_config` showed `host: ""`. We initially suspected a Docker
> Desktop bug. Dry-running the gateway (`docker mcp gateway run --profile <id> --verbose
> --dry-run`, which prints the literal `docker run` invocation) proved otherwise: the
> actual cause was our own `server.yaml`. A locally-built catalog (`docker mcp catalog
> create --server file://...`) needs a `value: "{{iris-agentic-dev.<NAME>}}"` template on
> each `env:` entry — `example:` alone silently resolves to `value: ""` and never gets
> wired to anything. Fixed in [`server.yaml`](../server.yaml) (see the schema note at its
> top) and confirmed by the same dry-run technique plus a live `check_config` call. See
> [docs/mcp-registry.md](mcp-registry.md) for the full writeup.
>
> **If you ever see `host: ""` again after editing `server.yaml`**, remember that
> rebuilding the catalog (`docker mcp catalog server add`) does **not** retroactively
> update a profile's cached snapshot — you have to remove and re-add the server on the
> profile too (`docker mcp profile server remove/add`), then reapply `profile config
> --set` and `profile tools --enable`.

## Prerequisites

- Docker Desktop for Windows, with the MCP Toolkit CLI available (`docker mcp --help`
  should print a command list — this ships with current Docker Desktop; no separate
  install step was found in Docker's docs beyond having Docker Desktop itself).
- An IRIS instance reachable from Docker Desktop's network — natively on Windows
  (`host.docker.internal`), in another container, or on a remote host.
- This repo cloned locally, with `.env` created from `.env.example` (see
  [README.md](../README.md#configuration)).

## Path A — Docker MCP Toolkit

Steps 1–3 are CLI-only — we confirmed live (see [Known GUI gaps](#known-gui-gaps-found-by-testing)
below) that Docker Desktop's GUI cannot do the catalog-from-local-file or
custom-catalog-server-search parts. Step 4 onward has a working GUI path.

**PowerShell tip:** run each command below as a single line. We hit a real, reproducible
issue pasting the backtick (`` ` ``) line-continuation style into PowerShell — it silently
joined two lines into one malformed command (e.g. `Out-Null` and the next line's
`Copy-Item` merged into `Out-NullCopy-Item`, a `CommandNotFoundException`). Single-line
commands avoid this entirely; that's what's below.

### 1. Build a local catalog from this repo's `server.yaml`

`docker mcp catalog create --server file://...` requires the file to resolve under
`~/.docker/mcp/catalogs/`, so copy it there first:

```powershell
New-Item -ItemType Directory -Force "$env:USERPROFILE\.docker\mcp\catalogs\iris-docker-mcp" | Out-Null
```

```powershell
Copy-Item .\server.yaml "$env:USERPROFILE\.docker\mcp\catalogs\iris-docker-mcp\server.yaml"
```

```powershell
docker mcp catalog create iris-mcp-catalog --title "IRIS Agentic Dev" --server file://iris-docker-mcp/server.yaml
```

Verify it resolved correctly:

```powershell
docker mcp catalog show iris-mcp-catalog:latest
```

You should see a `servers:` entry named `iris-agentic-dev` with `description`, `title`,
`icon` populated, pointing at `ghcr.io/intersystems-community/iris-agentic-dev:1.4.2`,
with `IRIS_HOST`, `IRIS_WEB_PORT`, etc. under `env:` and the password under `secrets:`.

> **If `description`/`title` come back missing** (e.g. you edited `server.yaml` and
> reintroduced an `about:`/`meta:` wrapper): the CLI will still accept it, but Docker
> Desktop's Profiles GUI will hard-crash with `Failed to load profiles` / a zod
> `invalid_type` error on `servers.0.snapshot.server.description` the moment *any*
> profile references it. We hit this ourselves. Fix is to keep `description`, `title`,
> `icon`, `readme` as top-level fields on the server object — see the schema note at the
> top of [server.yaml](../server.yaml).

### 2. Create a profile and configure the connection

A profile is the unit Docker's gateway actually runs. Pick a profile name per the
[profiles](../README.md#profiles) you want (`iris-readonly`, `iris-developer`,
`iris-operations`, or `iris-full`):

```powershell
docker mcp profile create --name iris-readonly --server "catalog://iris-mcp-catalog/iris-agentic-dev"
```

This prints the generated profile id (dashes become underscores, e.g. `iris_readonly`).
Set the connection env vars on that profile — the required syntax is
`<serverName>.<configName>=<value>`, where `<serverName>` is `iris-agentic-dev`:

```powershell
docker mcp profile config iris_readonly --set iris-agentic-dev.IRIS_HOST=host.docker.internal --set iris-agentic-dev.IRIS_WEB_PORT=52773 --set iris-agentic-dev.IRIS_NAMESPACE=USER --set iris-agentic-dev.IRIS_WRITE_TOOLS_ENABLED=0 --set iris-agentic-dev.IRIS_DESTRUCTIVE_TOOLS_ENABLED=0
```

Store the password as a Docker secret rather than plain config — either via CLI:

```powershell
echo "your-iris-password" | docker mcp secret set iris-agentic-dev.password
```

or via the GUI (see step 4 — the gear icon there is secrets-only, so it's actually a
convenient alternative to this one command specifically, just not to the `profile config`
command above).

Confirm everything landed:

```powershell
docker mcp profile show iris_readonly
```

### 3. Verify the gateway can see the tools

```powershell
docker mcp tools ls --gateway-arg --profile=iris_readonly
```

This lists the tool *names* the profile exposes — by default (`"tools": null` in `docker
mcp profile show`) every tool the image reports is enabled. Explicitly curate a tool set
for the profile to apply this project's "expose only what's needed" principle:

```powershell
docker mcp profile tools iris_readonly --enable iris-agentic-dev.check_config --enable iris-agentic-dev.iris_namespace_list --enable iris-agentic-dev.iris_query --enable iris-agentic-dev.iris_search --enable iris-agentic-dev.docs_introspect --enable iris-agentic-dev.iris_info --enable iris-agentic-dev.iris_table_info --enable iris-agentic-dev.my_access --enable iris-agentic-dev.iris_servers
```

Docker Desktop's Profiles → Tools tab will show **"No tools found"** for this server even
after this — that's a separate, cosmetic-only gap: the GUI reads a static `tools:` list
baked into the catalog snapshot, which official Docker Catalog entries have (Docker's own
publish pipeline introspects the container once and bakes it in) but our custom catalog
doesn't, since `server.yaml` deliberately has no hand-maintained `tools:` field. `docker
mcp tools ls --gateway-arg --profile=iris_readonly` remains the way to actually verify
which tools are enabled.

Verify actual connectivity with a live call:

```powershell
docker mcp tools call check_config --gateway-arg --profile=iris_readonly
```

This should return `"connected": true` with the real host/namespace and
`write_tools_source`/`destructive_tools_source` both `operator_env`. If you see `host: ""`
instead, you're likely running a profile whose server snapshot predates a `server.yaml`
edit — see the callout at the top of this doc for the remove/re-add fix.

### 4. Enable it in Docker Desktop and connect a client

Open **Docker Desktop → MCP Toolkit → Profiles**. Your `iris-readonly` profile (created
via CLI above) shows up here automatically — Docker Desktop and the CLI share the same
underlying state (`~/.docker/mcp/mcp-toolkit.db`). Click into it. You'll see:

- **Servers**: `InterSystems IRIS Agentic Dev`, with a gear icon that opens a **secrets-only**
  config dialog (good for the password; plain env vars still need step 2's CLI command).
- **Clients**: click **+**, pick your client (we tested VS Code), and it connects
  immediately, showing a `CONNECTED` badge. VS Code specifically prompts for a full
  restart before the new MCP server is usable — a window reload is not enough.

From the CLI instead:

```powershell
docker mcp client connect claude-code
```

(Supported clients per `docker mcp client --help`: `claude-code`, `claude-desktop`,
`cline`, `codex`, `continue`, `crush`, `cursor`, `gemini`, `goose`, `gordon`, `kiro`,
`lmstudio`, `opencode`, `sema4`, `vscode`, `zed`.)

Restart the client fully, then ask it to call `check_config` or `iris_namespace_list`.

### Known GUI gaps (found by testing)

- **No GUI way to build a catalog from a local `server.yaml`.** Docker Desktop's
  Catalog tab has an "Import catalog" button, but it only accepts an OCI registry
  reference (equivalent to `docker mcp catalog pull`) — it cannot take a local file. Step
  1 above has to be done via CLI.
- **Custom-catalog servers don't appear in the "Create profile" dialog's server search.**
  We confirmed `iris-agentic-dev` (from our custom catalog, with `description`/`title`
  correctly populated) never showed up searching "iris" in that dialog, even after
  scrolling the full unfiltered list. Only the official Docker MCP Catalog's servers are
  searchable there. Workaround: create the profile via CLI (step 2's `docker mcp profile
  create --server catalog://...`) — it then shows up correctly in the GUI once created,
  with the server card, gear icon, etc. all working.
- **The server config gear icon in a profile is secrets-only.** Plain env vars
  (`IRIS_HOST`, `IRIS_WEB_PORT`, `IRIS_WRITE_TOOLS_ENABLED`, …) aren't editable there —
  use `docker mcp profile config <id> --set <server>.<KEY>=<value>` instead.
- **The profile's Tools tab shows "No tools found" for a custom-catalog server**, even
  after tools are correctly enabled via CLI. Cosmetic only — see step 3 above for why.

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
docker run --rm -i --env-file .env -v "${PWD}\config\profiles\readonly.toml:/work/.iris-agentic-dev.toml:ro" -e OBJECTSCRIPT_WORKSPACE=/work ghcr.io/intersystems-community/iris-agentic-dev:1.4.2 mcp
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
