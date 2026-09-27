# Submitting to Docker's MCP Registry / Catalog

This describes what submitting `iris-agentic-dev` to
[docker/mcp-registry](https://github.com/docker/mcp-registry) would take. **Nothing has
been submitted.** This is investigation only, per the project brief.

## Prerequisites

- A `server.yaml` that validates against the registry's schema (see
  [Server definition](#server-definition--a-schema-discrepancy-we-found) below — we hit
  a real discrepancy here).
- A publicly pullable container image. `ghcr.io/intersystems-community/iris-agentic-dev`
  already satisfies this.
- Either:
  - **Self-provided image** (what this project would use): reference the existing GHCR
    image directly. Catalog-listed, but without Docker's own build signing/provenance/SBOM.
  - **Docker-built image**: hand Docker the source + a Dockerfile; Docker builds and
    publishes to `mcp/<name>` on Docker Hub within ~24h of merge, with cryptographic
    signatures, provenance tracking, and SBOMs.
- `task validate -- --name iris-agentic-dev` and `task build -- --tools
  iris-agentic-dev` passing locally (per docker/mcp-registry's `CONTRIBUTING.md`) — we
  did not run these, since that requires cloning docker/mcp-registry itself, which is out
  of scope for "investigate, don't submit."

## Which path fits here

**Self-provided image**, not Docker-built. `iris-agentic-dev` is not this project's
source to hand over — Docker's build pipeline would need to build someone else's Rust
workspace from a Dockerfile we don't control the release cadence of. Upstream already
publishes a signed, multi-arch, per-version-tagged image via its own GitHub Actions
release workflow; pointing the registry entry at that image is the option that doesn't
require any process change on either side.

## Required metadata

From what we could confirm in the registry's own examples and contribution guide:

- `name`, `type` (`server` for a real MCP server, vs. `poci` for a plain-CLI wrapper —
  `iris-agentic-dev` is `server`).
- `about.title`, `about.description`, `about.icon`, `about.readme`.
- `meta.category`, `meta.tags`.
- `source.project` (upstream repo URL) and `source.commit` (pinned commit for
  reproducibility).
- `container.image` (or top-level `image:` — see discrepancy below) and `command`.
- `secrets` / `env` describing what the server needs configured.

Our draft: [`server.yaml`](../server.yaml) at the repo root.

## Server definition — a schema discrepancy we found

`docker/mcp-registry`'s own `CONTRIBUTING.md` and the `curl` example server show
`config:` as a map with `description`, `secrets`, and `env` nested underneath it. We
built our first draft that way and **it failed against a real Docker Desktop install**:

```
failed to unmarshal server: yaml: unmarshal errors:
  line 50: cannot unmarshal !!map into []interface {}
```

The runtime on this machine expects `secrets:` and `env:` as **top-level** lists, not
nested under a `config:` map. After moving them to the top level, `docker mcp catalog
create ... --server file://server.yaml` succeeded and `docker mcp catalog show` returned
the expected resolved entry. We didn't have a live docker/mcp-registry checkout to run
its own `task validate` against, so we can't say for certain whether:

- the registry's PR-time validation (via `task validate`) is stricter/different from
  what a local Docker Desktop `docker mcp catalog create` accepts, or
- the CONTRIBUTING.md example is stale relative to the current schema.

**Whoever actually submits this should re-verify against `task validate` in a real
docker/mcp-registry checkout before opening a PR** — treat our `server.yaml` as a
locally-verified starting point, not a submission-ready file.

We also observed that `about`/`meta` fields (title, description, icon, tags) don't
appear in `docker mcp catalog show` output for a catalog built locally via `--server
file://` — they may only get surfaced by Docker's own registry build/publish pipeline,
not by the local catalog CLI. Unconfirmed; flagging it rather than guessing further.

## Image requirements

- Multi-arch (amd64/arm64) — upstream's image already is.
- Pullable without auth from the referenced registry (GHCR, public) — confirmed by
  pulling it directly in this repo's development.
- Pinned by tag (and ideally digest) rather than `latest` in the submitted `server.yaml`
  — our draft pins `1.4.2`.

## Security considerations for a registry listing

- The registry entry can declare `env`/`secrets` names, but has no field for
  "recommended safe defaults" beyond the `example` values shown in Docker Desktop's
  config UI. A reviewer or user copying those examples verbatim would get
  `IRIS_WRITE_TOOLS_ENABLED=0` / `IRIS_DESTRUCTIVE_TOOLS_ENABLED=0` from our draft, which
  is the safe default — but nothing in the registry schema *enforces* that a submitter
  picks safe example values instead of permissive ones.
- Docker's MCP Toolkit tool-level enable/disable (profiles) is a gateway-side filter, not
  something declared in `server.yaml` — it's configured per-profile after the server is
  added to a catalog, so there's nothing registry-side to set here. See
  [docs/security.md](security.md).
- The registry has no concept of `iris-agentic-dev`'s own write/destructive/category
  gates — those live entirely in env vars and an optional mounted TOML file, both of
  which are representable in `server.yaml`'s `env`/`secrets` lists. No registry-side gap
  found here.

## What would need to change upstream

Nothing is required in `iris-agentic-dev` to make a registry submission possible — the
existing image, env-var interface, and stdio transport are already sufficient. Two things
would be *nice to have* upstream but aren't blockers:

1. A `docs.intersystems.com`-hosted or upstream-repo-hosted `server.yaml` (or a link to
   one) so a Docker MCP Registry entry could point at an upstream-maintained definition
   instead of one living in this separate integration repo — reduces drift as
   `iris-agentic-dev` adds tools/env vars across releases.
2. Upstream publishing a `latest-stable` or similar floating tag alongside per-version
   tags, if Docker's registry process prefers a non-`latest` floating reference over a
   fully pinned one. Not confirmed as a requirement — pinned tags worked fine for us.

Neither of these blocks anything in this project; both are upstream-repo decisions to
raise separately if this integration is ever handed off.
