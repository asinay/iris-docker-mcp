# Submitting to Docker's MCP Registry / Catalog

`iris-agentic-dev` has been submitted: [docker/mcp-registry#5281](https://github.com/docker/mcp-registry/pull/5281),
cleared with upstream's maintainer beforehand. This doc now describes what that took,
including two schema questions this repo's own `server.yaml` originally got wrong before
we had a real `docker/mcp-registry` checkout to test against.

## Two different `server.yaml` schemas — don't confuse them

There are two unrelated schemas that happen to share a filename:

- **This repo's [`server.yaml`](../server.yaml)** (flat, top-level `name`/`type`/`image`/
  `description`/`title`/`icon`/`readme`/`secrets`/`env`) is what a *local* Docker Desktop
  install's `docker mcp catalog create --server file://...` consumes directly. It's for
  anyone who wants `iris-agentic-dev` in their own Docker MCP Toolkit without going
  through Docker's registry — see [docs/windows-setup.md](windows-setup.md) Path A.
- **The registry submission's `server.yaml`** (nested `about:`/`meta:`/`config:`, with
  `config.secrets`/`config.env`/`config.parameters`) is what `docker/mcp-registry`'s own
  Go tooling (`task validate`/`task build`/`task catalog`) actually parses — confirmed by
  reading `pkg/servers/types.go` in a real checkout and by every check in `task validate`
  passing only once the file used this shape. It lives in the PR, at
  `servers/iris-agentic-dev/server.yaml` in [asinay/mcp-registry](https://github.com/asinay/mcp-registry),
  not in this repo.

We originally assumed these were the same schema and that CONTRIBUTING.md's wrapped
example was stale, because our flat file passed `docker mcp catalog create` locally. That
assumption was wrong on both counts — resolved below.

## Prerequisites (all satisfied by the PR)

- A `server.yaml` validating against the registry's actual schema — confirmed via
  `go run ./cmd/validate --name iris-agentic-dev` in a real `docker/mcp-registry`
  checkout: Name/Directory/Title/YAML formatting/Commit pinned/Secrets/Config env/
  License/Icon all pass.
- A publicly pullable container image: `ghcr.io/intersystems-community/iris-agentic-dev`,
  pinned to the commit tagged v1.4.2.
- **Self-provided image**, not Docker-built (see [Which path fits here](#which-path-fits-here)).
- `task build -- --tools iris-agentic-dev --pull-community` — pulled the real image,
  found 81 tools.
- `task catalog -- iris-agentic-dev` — compiled a local catalog; imported it into a
  scratch Docker Desktop profile and made a live `check_config` call against a real IRIS
  instance (`connected: true`, correct host/namespace, safety env vars sourced from
  `operator_env`).

None of this needed installing Go or Task on the host — all three commands ran inside
throwaway `golang:1.24` containers (Docker socket bind-mounted for the steps that shell
out to `docker`), so nothing was left behind on the machine that built this.

## Which path fits here

**Self-provided image**, not Docker-built. `iris-agentic-dev` is not this project's
source to hand over — Docker's build pipeline would need to build someone else's Rust
workspace from a Dockerfile we don't control the release cadence of. Upstream already
publishes a signed, multi-arch, per-version-tagged image via its own GitHub Actions
release workflow; pointing the registry entry at that image is the option that doesn't
require any process change on either side.

## Required metadata (confirmed against the real schema)

From `pkg/servers/types.go` in a real `docker/mcp-registry` checkout, not just examples:

- `name`, `image`, `type` (`server` for a real MCP server).
- `about.title`, `about.description`, `about.icon` — there is no `about.readme` field;
  remote-server `readme.md` files are a separate, remote-server-only convention.
- `meta.category`, `meta.tags`.
- `source.project`, `source.commit`.
- `run.command` (only needed if the image's default entrypoint isn't already stdio-MCP —
  ours needs `["mcp"]`).
- `config.description`, `config.secrets`, `config.env`, `config.parameters` (a JSON
  Schema — `required` on a property forces Docker Desktop's config form to make the user
  fill it in before the server can start).

Submitted file: [`servers/iris-agentic-dev/server.yaml`](https://github.com/asinay/mcp-registry/blob/add-iris-agentic-dev/servers/iris-agentic-dev/server.yaml)
in the fork backing PR #5281.

## Schema discrepancy #1 (resolved): `config:` wrapper is correct, not stale

We originally built a draft with `secrets:`/`env:` nested under a `config:` map, matching
CONTRIBUTING.md, and it failed against local Docker Desktop:

```
failed to unmarshal server: yaml: unmarshal errors:
  line 50: cannot unmarshal !!map into []interface {}
```

We concluded (wrongly) that Docker Desktop's own runtime wanted `secrets:`/`env:` at the
**top level**, and built this repo's `server.yaml` that way instead — which does work,
but only because it's a *different, local-only* catalog schema (see above), not because
the `config:` wrapper was wrong. `docker/mcp-registry`'s own `Server` struct
(`pkg/servers/types.go`) confirms `config:` is correct for a registry submission — our
top-level file simply isn't parsed by that struct at all; unrecognized top-level fields
are silently ignored by Go's YAML unmarshaling, which is why it never errored.

## Schema discrepancy #2 (resolved): `about:`/`meta:` wrappers are correct too

For the same reason as #1: our first draft nested `title`/`description`/`icon` under
`about:` and `category`/`tags` under `meta:`, then we moved them to the top level after
`docker mcp catalog create` silently dropped them and Docker Desktop's Profiles GUI
hard-crashed (`Failed to load profiles`, a zod `invalid_type` error on
`servers.0.snapshot.server.description`) the moment a profile referenced the resulting
server. That crash is real and still worth knowing about — but it's specific to this
repo's local, flat catalog schema. The registry's `about:`/`meta:` wrapper is correct as
CONTRIBUTING.md documents it; `isIconValid` in `cmd/validate/main.go` reads
`server.About.Icon` directly, confirming the wrapper is load-bearing, not decorative.

**Takeaway for this repo's own `server.yaml`:** keep `description`/`title`/`icon`/
`readme`/`secrets`/`env` at the top level — that's genuinely required for the local-catalog
path this repo documents. Just don't take that as evidence about the registry's own
schema; it isn't the same parser.

## Schema discrepancy #3 (resolved): `value:` templates are required in both schemas, not auto-generated

`docker/mcp-registry`'s `CONTRIBUTING.md` documents `example` as the field that shows a
placeholder value for a plain (non-secret) `env:` entry. We shipped this repo's
`server.yaml` with only `example:` per entry and it looked fine — `docker mcp catalog
create` accepted it, `docker mcp profile config <id> --set iris-agentic-dev.IRIS_HOST=...`
accepted and stored values, `docker mcp profile show` displayed them under `config:`.
**None of it actually reached the container.**

We only caught this by dry-running the gateway (`docker mcp gateway run --profile
iris_readonly --verbose --dry-run`), which prints the literal `docker run` invocation. It
showed `-e IRIS_PASSWORD` (the one secret) and nothing else — every plain env var was
silently dropped, so the container always ran with `IRIS_HOST=""`, and every tool call
failed with `IRIS_UNREACHABLE`. `check_config` (which never touches IRIS) still returned
`connected: false, host: "", namespace: ""` — a strong signal the container never saw the
configured values, worth checking any time a profile's tools inexplicably can't reach a
backend.

Root cause: the resolved catalog snapshot needs a `value: "{{<server-name>.<key>}}"`
template on each `env:` entry, binding it to a `config.parameters` property name — same
convention Docker's own published catalog entries use (e.g. `docker mcp catalog show
mcp/docker-mcp-catalog:latest` — `airtable-mcp-server`'s `NODE_ENV` has `value:
"{{airtable-mcp-server.nodeenv}}"`). Without it, a locally-built catalog resolves the
entry to `value: ""` — accepted silently, never bound to anything.

This is **not** auto-generated from `example:` by Docker's build pipeline, confirmed
directly this time, not guessed: `docker/mcp-registry`'s own `CONTRIBUTING.md` example for
`AWS_ACCESS_KEY_ID` hand-writes both `example` and `value` side by side, and
`isConfigEnvValid` in `cmd/validate/main.go` only checks `server.Config.Env[i].Value`
against a `{{<server-name>.` prefix — there's no code path that derives `value:` from
`example:`. Both this repo's local-catalog `server.yaml` and the registry submission's
`server.yaml` carry explicit `value:` templates on every plain `env:` entry as a result.

## Image requirements

- Multi-arch (amd64/arm64) — upstream's image already is.
- Pullable without auth from the referenced registry (GHCR, public) — confirmed by
  pulling it directly, both in this repo's development and via `task build --tools
  --pull-community` against the registry's own tooling.
- Pinned by tag (and ideally digest) rather than `latest` — both `server.yaml` files pin
  `1.4.2`.

## Security considerations for a registry listing

- The registry entry can declare `config.env`/`config.secrets`, and `config.parameters`
  can mark a property `required` — Docker Desktop's config form then forces the user to
  type a value before the server starts. We used this for `write-tools-enabled` and
  `destructive-tools-enabled` in the submitted `server.yaml`, with `"0"` as the shown
  example, specifically so no installer ends up on a permissive default just by skipping
  an optional field.
- Docker's MCP Toolkit tool-level enable/disable (profiles) is a gateway-side filter, not
  something declared in `server.yaml` — it's configured per-profile after the server is
  added to a catalog, so there's nothing registry-side to set here, and the registry
  cannot ship a "recommended restricted profile" for anyone installing from the catalog.
  Every install starts with all 81 tools enabled. See [docs/security.md](security.md) and
  this repo's `config/profiles/*.toml` for a curated starting point users have to apply
  themselves.
- The registry has no concept of `iris-agentic-dev`'s own write/destructive/category
  gates beyond the env vars above and an optional mounted TOML file (`OBJECTSCRIPT_WORKSPACE`
  + a `.iris-agentic-dev.toml`) — the latter isn't representable in the registry schema at
  all (no volume-mount concept for a config file that isn't a secret), so registry
  installs are limited to the env-var-only gates.

## What would need to change upstream

Nothing was required in `iris-agentic-dev` to make this submission possible — the
existing image, env-var interface, and stdio transport were already sufficient. Two
things would be *nice to have* upstream but aren't blockers:

1. A `docs.intersystems.com`-hosted or upstream-repo-hosted `server.yaml` (or a link to
   one) so a Docker MCP Registry entry could point at an upstream-maintained definition
   instead of one living in a separate fork — reduces drift as `iris-agentic-dev` adds
   tools/env vars across releases.
2. Upstream publishing a `latest-stable` or similar floating tag alongside per-version
   tags, if Docker's registry process prefers a non-`latest` floating reference over a
   fully pinned one. Not confirmed as a requirement — pinned tags worked fine here.

Neither of these blocks anything in this project; both are upstream-repo decisions to
raise separately if this integration is ever handed off.
