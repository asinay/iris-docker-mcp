# Security model

This project adds no security controls of its own. Every gate described below is
implemented by `iris-agentic-dev` itself; this document explains how to configure the
existing controls safely, and where they fall short. If upstream cannot enforce
something, that is stated explicitly rather than papered over.

Treat AI access to an IRIS instance as privileged access. The controls below reduce
blast radius; they do not make arbitrary tool exposure safe against a hostile or
badly-prompted client.

## The three layers

`iris-agentic-dev` checks write-capable tool calls in this order (from
[docs/tools.md](https://github.com/intersystems-community/iris-agentic-dev/blob/master/docs/tools.md)
in the upstream repo):

1. `write_tools_enabled` — if false, every write-capable tool returns `WRITE_TOOLS_DISABLED`.
2. `destructive_tools_enabled` — if false, the 7 tools marked ☠ return `DESTRUCTIVE_TOOLS_DISABLED`, even with (1) true.
3. `policy.<connection>.allow` — a category allowlist checked per call; blocked calls return `POLICY_GATE`.
4. Data-safety gates — PHI patterns, a hardcoded system-global blocklist, and the `mcpTemplate` environment gate.

Read-only tools skip (1) and (2) entirely — there is no way to gate a read call through
`write_tools_enabled`/`destructive_tools_enabled`, only through (3) and (4).

## ⚠️ The default is not fail-safe — verified by testing, not assumed

If you don't set `write_tools_enabled` explicitly, `iris-agentic-dev` **infers** it from
your namespace name. We tested this directly against the published image:

| `IRIS_NAMESPACE` | `write_tools_enabled` (no explicit setting) |
| ---------------- | -------------------------------------------- |
| `USER`           | `true` (inferred) |
| `PROD`           | `false` (inferred) |

`USER` is IRIS's most common default namespace. If you only set connection variables and
skip the security ones, **write tools are enabled by default** on a typical IRIS
instance. `destructive_tools_enabled` does default to `false` and is never inferred, so
that one gate is safe to leave unset — but don't assume the same about writes.

**Always set both explicitly:**

```env
IRIS_WRITE_TOOLS_ENABLED=0
IRIS_DESTRUCTIVE_TOOLS_ENABLED=0
```

`.env.example` in this repo already does this. `check_config` reports which source won
in `write_tools_source` (`operator_env`, `inferred_namespace`, `inferred_default`, …) —
the smoke test script (`scripts/test.ps1` / `scripts/test.sh`) warns you if it sees
`inferred_*` instead of `operator_env`.

## Category allowlist (`policy.<name>.allow`)

`iris-agentic-dev` groups its ~80 tools into 10 categories: `compile`, `execute`,
`query`, `search`, `docs`, `source_control`, `debug`, `admin`, `skill`, `kb`. This is
upstream's own grouping — this project does not maintain a separate list of tool names
per category, to avoid drifting out of sync as tools are added or removed upstream.

Set it in a `.iris-agentic-dev.toml` file, under `[policy.default]` for a plain
single-connection setup (no VS Code Server Manager):

```toml
[policy.default]
allow = ["query", "search", "docs"]
```

Omitting the `[policy.default]` block entirely permits every category — that is
upstream's own behavior, not something this project adds.

This file has to be mounted into the container and pointed at with
`OBJECTSCRIPT_WORKSPACE` (see [windows-setup.md](windows-setup.md)); it is not something
you can pass as a plain environment variable. `config/profiles/*.toml` in this repo has
one ready-made file per profile described below.

## `IRIS_ENABLED_TOOLS` (optional extra trim)

A comma-separated allowlist of **exact tool names** (not categories):

```env
IRIS_ENABLED_TOOLS=iris_query,iris_search,check_config
```

This is a plain env var — no file mount needed — which makes it the easiest option to
use through Docker MCP Toolkit's own secret/env UI. It's coarser to maintain than the
category gate (you're naming individual tools, and the tool surface changes across
upstream releases), so treat it as an optional way to hide a handful of specific tools
further, not as the primary boundary. The category gate above and the write/destructive
gates are the real enforcement; `IRIS_ENABLED_TOOLS` only controls what the client sees
in `tools/list`.

## Docker MCP Toolkit's own tool filtering

Independently of all of the above, Docker MCP Toolkit has a profile-level tool
enable/disable (`docker mcp profile tools <profile-id> --enable/--disable
<server>.<tool>`, or the "Tools" tab in Docker Desktop's profile editor). This is a
**UX/context-reduction layer at the gateway**, not a security boundary enforced by IRIS
or by iris-agentic-dev — it controls what the gateway advertises to the client. Use it to
trim noise in a client's tool list; don't rely on it as your only control for
write/destructive access. Put the real enforcement in the env vars and TOML above, and
use Docker's profile tool list as a second, convenient layer on top.

## Privilege separation for arbitrary execution

`iris_execute`, `iris_execute_method`, `iris_query(mode="write")`, and
`iris_global(set|kill)` run arbitrary ObjectScript/SQL. Under a `%All` IRIS account these
can edit compiled code by indirection, bypassing source-control locks.

Set `IRIS_SERVICE_USERNAME` / `IRIS_SERVICE_PASSWORD` to a least-privilege IRIS account
(no `%Development` resource, code database mounted read-only). Those four tools then
authenticate as that account instead of `IRIS_USERNAME`; code-writing tools (`iris_doc`
put, `iris_source_control`, `iris_compile`) keep using the primary account so audit stays
attributed to the real user.

## Other gates that exist but are not configured by this project

- **`mcpTemplate`** (TOML only, no env var found): `dev` (default, permits everything),
  `test` (blocks execution/compile), `live` (blocks those plus source control).
- **`dataPolicy`** (`block`/`allow`/`redact`, default `block`): gates bulk-PHI tools
  (`journal_search`, `iris_message_body`).
- **System global blocklist** (`^oddDEF`, `^ROUTINE`, `^%Dictionary*`, `^ROLE`,
  `^Ens.Config*`): hardcoded, cannot be disabled.
- **PHI-name-pattern gate** on globals like `^PAPMI*`, `^PAADM*`: requires
  `acknowledgePhi: true` per call.

We didn't build example configs for these because they're per-deployment decisions
(what counts as PHI, what your "live" instances are) that this project has no way to
make safely on your behalf. See
[docs/tools.md](https://github.com/intersystems-community/iris-agentic-dev/blob/master/docs/tools.md#data-safety-gates)
upstream if you need them.

## What upstream does *not* enforce

- **No per-server write allowlist.** Upstream's own docs say this explicitly: a write
  enabled for one connection is enabled against every server the process can reach. If
  you need different write posture for different IRIS servers, run separate containers
  with separate `.iris-agentic-dev.toml`/env files — don't rely on one process serving
  multiple servers with different trust levels.
- **HTTP transport has no authentication.** If you run `iris-agentic-dev mcp --transport
  http`, upstream's docs state there is no auth on that endpoint. Bind it to loopback
  only (this repo's `docker-compose.yml` publishes it to `127.0.0.1` only, never `0.0.0.0`
  on the host).
- **`docker mcp profile tools` filtering is client-facing only**, as noted above — don't
  treat it as IRIS-side enforcement.

## Recommended baseline

For a first-time setup, start with the **Read Only** profile
(`config/profiles/readonly.toml` + `IRIS_WRITE_TOOLS_ENABLED=0` +
`IRIS_DESTRUCTIVE_TOOLS_ENABLED=0`) against a non-production namespace, confirm the
smoke test passes, and only then move to Developer/Operations/Full as documented in
[README.md](../README.md#profiles).
