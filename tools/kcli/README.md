# kcli

> Cortex Cloud konnector CLI — currently focused on **mirroring konnector
> container images** to a private container registry.

`kcli` is a small, focused command-line tool for operating the Palo Alto
Networks Cortex Cloud konnector Helm chart in **air-gapped or
private-registry** environments.

The first (and currently only) subcommand is `kcli mirror`. Given the
konnector Helm chart archive (`.tgz`, bundle v2+) and the operator's
Helm values file, it will:

1. Verify the chart advertises a supported konnector bundle version
   (`Chart.yaml` `version` major `>= 2`; `appVersion` is used as a
   fallback when `version` is missing).
2. Pull every container image declared by the chart under
   `global.bundle.<comp>.image` from the source registry, preserving
   multi-arch manifests.
3. Re-push them into a private container registry of your choice.
4. **Rewrite the operator's `--values` file in place** so it points the
   chart at the mirrored registry — setting `global.imageRegistry`, any
   per-component `global.bundle.<comp>.image.repository` overrides that
   already exist, and (optionally) `global.dockerPullSecret`. A
   timestamped `.bak` copy of the original file is written next to it
   before any change.

The mirroring logic is functionally equivalent to the
`cortex-installer mirror` subcommand on the
[`standalone-installer`](https://github.com/PaloAltoNetworks/cortex-cloud/tree/standalone-installer)
branch, packaged with a CLI structure modelled after
[PaloAltoNetworks/ktool](https://github.com/PaloAltoNetworks/ktool/blob/main/kubectl-ktool.sh)
(subcommand dispatcher, dedicated `version` command, semver
`parse_major_version` helper).

> 🔧 **Installation of the chart itself is not in scope for this tool.**
> After `kcli mirror` finishes, follow the installation instructions for
> your tenant in the **Cortex Cloud portal** — the portal is the
> single source of truth for the canonical install flow.

---

## Table of contents

- [Why this tool?](#why-this-tool)
- [Bundle compatibility](#bundle-compatibility)
- [How it works](#how-it-works)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Staying current (mandatory version check)](#staying-current-mandatory-version-check)
- [Commands](#commands)
  - [`kcli mirror`](#kcli-mirror)
  - [`kcli version`](#kcli-version)
  - [`kcli help`](#kcli-help)
- [Inputs](#inputs)
- [`dockerPullSecret` semantics](#dockerpullsecret-semantics)
- [What `kcli mirror` writes](#what-kcli-mirror-writes)
- [Environment variables](#environment-variables)
- [Exit codes](#exit-codes)
- [Logging & diagnostics](#logging--diagnostics)
- [Security notes](#security-notes)
- [License](#license)

---

## Why this tool?

The default konnector install pulls images directly from the Palo Alto
Networks distribution registry. In environments where worker nodes cannot
reach the public internet — or where customer policy mandates that all
container images live in an internal registry — operators need to:

1. Discover **which images** the chart needs for the customer's bundle
   subscription.
2. Pull every image (across all supported architectures).
3. Re-push them into a private registry under stable tags.
4. Patch the chart's `global.imageRegistry` (and any per-component
   overrides) so pods pull from the new location.
5. Update `global.dockerPullSecret` so Kubernetes nodes can authenticate
   to the private registry.

`kcli mirror` automates steps 1–5. The end-state is the operator's same
`--values` file, mutated in place to point at the mirrored registry, ready
to be passed straight into the chart install (per the Cortex Cloud portal
flow).

---

## Bundle compatibility

This tool supports konnector **bundle v2 or higher** only. The version
gate is read from the chart archive's `Chart.yaml`:

```yaml
# inside the .tgz: konnector-bundle/Chart.yaml
apiVersion: v2
name: konnector-bundle
version: 2.0.41        # ← bundle version gate; major must be >= 2
appVersion: v2.0.41    # fallback if 'version' is absent
```

The customer **values file** (`--values`) stays minimal — it supplies
the source registry, the source-registry pull secret, and the
deployment environment used to resolve per-env image tags:

```yaml
global:
  imageRegistry: "us-docker.pkg.dev/cortex-konnector/konnector"
  dockerPullSecret: "<base64-encoded-docker-config-json>"
  metadata:
    env: "prod"   # one of: dev | prod | fr | gov
```

The list of mirrorable images is read from the chart's own `values.yaml`
under `global.bundle.<comp>.image` — every component the chart knows
about is mirrored. Components whose tag is provided per-env (e.g.
`cortex-agent` ships as `image.tagsByEnv.{dev,prod,fr,gov}` instead of
a static `image.tag`) are resolved against `global.metadata.env`.

`kcli mirror` reads:

| What                            | Path                                                                |
|---------------------------------|---------------------------------------------------------------------|
| Bundle version (gate)           | `version` (with `appVersion` fallback) from chart `Chart.yaml`      |
| Source registry / repo path     | `global.imageRegistry` (from `--values`)                            |
| Source-registry pull credentials| `global.dockerPullSecret` (from `--values`)                         |
| Deployment env (per-env tags)   | `global.metadata.env` (from `--values`) — `dev`/`prod`/`fr`/`gov`   |
| Mirrorable image catalog        | `global.bundle.<comp>.image` (from chart `values.yaml`)             |

…and **rewrites** the operator's `--values` file in place:
`global.imageRegistry` and any per-component
`global.bundle.<comp>.image.repository` overrides that already exist are
pointed at the mirror, plus `global.dockerPullSecret` is set/removed per
the CLI flags.

Older bundles are **not supported** by this mirror flow — `kcli mirror`
exits with exit code `1` and a clear error message before any registry
traffic happens:

```text
[ERROR] Unsupported bundle version: chart version = '1.5.0' (major=1).
[ERROR] The mirror flow requires konnector bundle v2 or higher.
[ERROR] Please upgrade to a v2+ bundle and retry.
```

The version-parsing helper (`parse_major_version`) follows the same
convention as
[ktool](https://github.com/PaloAltoNetworks/ktool/blob/main/kubectl-ktool.sh):
a leading `v` is optional and pre-release/build metadata is ignored.

---

## How it works

```
┌──────────────────────────┐     ┌─────────────────────────────────────┐
│  --chart  <chart.tgz>    │     │  Source container registry          │
│  --values <values.yaml>  │ ──► │  (defined by global.imageRegistry   │
│   (global.bundle.*       │     │   in --values; auth via             │
│    declares enabled      │     │   global.dockerPullSecret)          │
│    components)           │     └────────────────┬────────────────────┘
└──────────────────────────┘                      │ docker pull (multi-arch)
                                                  ▼
                                  ┌──────────────────────────────────────┐
                                  │  Local Docker daemon                 │
                                  └────────────────┬─────────────────────┘
                                                   │ buildx imagetools create
                                                   ▼
                                  ┌──────────────────────────────────────┐
                                  │  --private-registry                  │
                                  └──────────────────────────────────────┘

In-place edit:
  --values <file>  →  global.imageRegistry        := <push-target>
                      global.bundle[*].image.repository (where present)
                                                  := <push-target>
                      global.dockerPullSecret     := <secret>  (if provided)
                      <file>.bak.<UTC-timestamp>  ← byte-for-byte original
```

---

## Prerequisites

| Tool             | Minimum version | Why                                          |
|------------------|-----------------|----------------------------------------------|
| `bash`           | 4.0             | Arrays, `[[ … ]]`, traps                     |
| `docker`         | 20.10           | Image pull/push                              |
| `docker buildx`  | bundled         | Multi-arch manifest copy                     |
| `curl`           | any             | Mandatory upstream-version check (skipped if absent) |
| `jq`             | 1.6             | JSON manipulation                            |
| `yq`             | 4.x (mikefarah) | YAML manipulation (the **Go** version)       |
| `tar`            | any             | Chart-archive extraction                     |
| `base64`         | GNU or BSD      | Decoding the dockerPullSecret                |

The tool detects missing prerequisites and prints actionable error messages
before doing any work.

> ⚠️ **Note:** the python `yq` (`pip install yq`) is **not** compatible —
> install the Go binary from <https://github.com/mikefarah/yq>.

---

## Installation

`kcli` is a single self-contained bash script. There are no release
artifacts — the canonical copy lives at `tools/kcli/kcli` on the
`main` branch of this repository, and that file is exactly what you
run.

### Clone & symlink (recommended)

```bash
git clone https://github.com/PaloAltoNetworks/cortex-cloud.git
cd cortex-cloud
sudo ln -sf "$PWD/tools/kcli/kcli" /usr/local/bin/kcli
kcli version
```

To stay current, just pull the latest `main`:

```bash
cd /path/to/cortex-cloud
git pull origin main
```

### Direct download (no clone)

```bash
sudo curl -fsSL \
  https://raw.githubusercontent.com/PaloAltoNetworks/cortex-cloud/main/tools/kcli/kcli \
  -o /usr/local/bin/kcli
sudo chmod +x /usr/local/bin/kcli
kcli version
```

To update later, re-run the same `curl` to overwrite the file in place.

### Run from source

```bash
./tools/kcli/kcli help
```

---

## Staying current (mandatory version check)

Every invocation of `kcli` (other than `version` / `help`) parses the
`VERSION="x.y.z"` constant out of the canonical copy on `main` and
compares it to the local one. When the local script is older, `kcli`
**hard-fails before running anything** with an actionable remediation
message:

```text
[ERROR] A newer kcli version is available.
[ERROR]   installed: v1.0.0
[ERROR]   upstream:  v1.1.0
[ERROR]
[ERROR] kcli requires the latest version. Update before retrying:
[ERROR]   - If installed via 'git clone':  cd <repo> && git pull
[ERROR]   - If installed by file copy:     re-fetch tools/kcli/kcli from
[ERROR]       https://raw.githubusercontent.com/PaloAltoNetworks/cortex-cloud/main/tools/kcli/kcli
```

The exit code in this case is `65` (data-format mismatch), distinct
from the usage error (`64`) and runtime errors (`1`) so CI pipelines
can distinguish "needs update" from "real failure".

### When the check is skipped

The check is best-effort by design — it must never become a footgun
for legitimate operators on slow / restricted networks. It is skipped,
with a `[WARN]` line, in any of:

- `curl` is not installed.
- The GitHub fetch times out (5 s) or returns no parseable VERSION.
- `KCLI_SKIP_VERSION_CHECK=1` is exported (for air-gapped /
  internally-vendored installs where remote fetch is impossible by
  policy).

In all skip cases the local script still runs — operators just don't
get the "you're stale" guarantee.

### Local builds ahead of upstream

If your local `VERSION` is *higher* than the one on `main` (e.g.
you're working on a feature branch), `kcli` warns once and proceeds
— development builds are explicitly allowed to run.

---

## Commands

```text
kcli <command> [options]

Commands:
  mirror     Pull bundle container images from the source registry and push
             them to a private registry (preserving multi-arch manifests).
             Updates the --values file in place to point at the mirror
             (a timestamped .bak is written first).
  version    Print the kcli version.
  help       Show top-level help.
```

### `kcli mirror`

```text
Usage:
  kcli mirror --chart <chart.tgz> --values <values-file> \
              --private-registry <registry> [options]

Required:
  --chart <chart.tgz>              Path to the konnector Helm chart archive
                                   (the .tgz issued for your tenant)
  --values <values-file>           Helm values YAML (read AND written in place
                                   — provides global.bundle.* enable map,
                                   source-registry credentials, and gets
                                   rewritten to point at the mirror)
  --private-registry <registry>    Target registry, e.g.
                                   myregistry.azurecr.io/proj/repo

Optional:
  --docker-pull-secret <secret>    Base64-encoded dockerPullSecret for the
                                   private registry (written into the
                                   --values file under global.dockerPullSecret)
  --docker-pull-secret-file <file> Path to a Docker config JSON for the
                                   private registry (will be base64-encoded
                                   and written as global.dockerPullSecret)
  --no-pull-secret                 Strip global.dockerPullSecret from the
                                   --values file (use only if the cluster
                                   already has access)
  --dry-run                        Show what would be done without pulling
                                   or pushing images. The --values file is
                                   NOT rewritten in dry-run mode.
  -h, --help                       Show command help
```

#### Quick start

```bash
kcli mirror \
  --chart ./konnector-2.0.0.tgz \
  --values ./my-values.yaml \
  --private-registry myregistry.azurecr.io/cortex \
  --docker-pull-secret-file ~/.docker/config.json
```

After mirroring completes, install the konnector chart by following the
**Cortex Cloud portal** instructions for your tenant, passing the
(now-rewritten) `./my-values.yaml` as the Helm values file.

#### Behaviour highlights

- **Bundle-version gate.** Before any registry traffic, the chart's
  `global.version` is verified to be `>= v2`; older bundles fail fast
  with an actionable error message (see [Bundle compatibility](#bundle-compatibility)).
- **Multi-arch awareness.** Each image is inspected via
  `docker manifest inspect`. Every `linux/*` platform is pulled
  individually, and the destination tag is created with
  `docker buildx imagetools create` so the multi-arch index is preserved.
- **Single-arch fallback.** If `buildx imagetools` fails for some reason,
  the tool falls back to `docker tag` + `docker push` and reports the
  result as a single-arch push.
- **Per-component repository overrides.** When the values file contains
  `global.bundle.<component>.image.repository`, those entries are also
  rewritten to point at the mirror; entries without an explicit
  `repository` are left untouched (no spurious key is injected).
- **Backup before mutation.** A timestamped copy
  `<values-file>.bak.YYYYMMDDTHHMMSSZ` is written before the rewrite, so
  you can always roll back with `mv <values-file>.bak.* <values-file>`.
- **Dry-run** (`--dry-run`) skips every network operation, leaves the
  `--values` file untouched (no rewrite, no `.bak`), and prints exactly
  what would have happened — useful for change-management reviews.

### `kcli version`

```bash
$ kcli version
kcli v1.0.0

# `-v` and `--version` are accepted as aliases:
$ kcli --version
kcli v1.0.0
```

The version string is the `VERSION="x.y.z"` constant declared at the
top of `tools/kcli/kcli`. See
[Staying current (mandatory version check)](#staying-current-mandatory-version-check)
for how this value is compared against the canonical copy on
`main` on every invocation.

### `kcli help`

```bash
kcli help
kcli --help
kcli -h
```

All three forms print the top-level usage. For command-specific help, use
`kcli <command> --help` (e.g. `kcli mirror --help`).

---

## Inputs

`kcli mirror` takes two file inputs:

| Flag       | What                                                                |
|------------|---------------------------------------------------------------------|
| `--chart`  | The konnector Helm chart archive (`.tgz` or `.tar.gz`, bundle v2+). |
| `--values` | The customer values YAML issued for your tenant.                    |

The values file only carries what is tenant-specific:

- `global.imageRegistry` — source registry / repo path used for pull.
- `global.dockerPullSecret` — base64 Docker config used to authenticate
  against the **source** registry (and the field `kcli` rewrites with
  the **private** registry credential at the end of the run).
- `global.metadata.env` — deployment environment (one of
  `dev` / `prod` / `fr` / `gov`). Used to resolve per-env image tags
  from the chart's `image.tagsByEnv.<env>` map. Components whose tag
  is supplied only via `tagsByEnv` (e.g. `cortex-agent`) are SKIPPED
  if `global.metadata.env` is missing or doesn't match a key in the
  map.

The bundle version gate (`Chart.yaml` `version`, with `appVersion` as a
fallback; major `>= 2`) and the catalog of mirrorable images
(`global.bundle.<comp>.image` from the chart's own `values.yaml`) are
read from `--chart` — the customer values file does not need to
enumerate them.

See [`examples/values-example.yaml`](examples/values-example.yaml) for the
minimum shape of the values file.

---

## `dockerPullSecret` semantics

When mirroring to a private registry, the cluster needs credentials to pull
from your private registry. `kcli` enforces this explicitly — you must
provide one of:

| Flag                                 | When to use                                                         |
|--------------------------------------|---------------------------------------------------------------------|
| `--docker-pull-secret <base64>`      | You already have the secret material as a base64 blob.              |
| `--docker-pull-secret-file <path>`   | You have a Docker `config.json` — the tool base64-encodes it.       |
| `--no-pull-secret`                   | The cluster nodes have pre-configured access (e.g. IRSA, IAM, ECR). |

Omitting all three flags is a hard error — this prevents leaving the
values file in a state that silently fails at install time with
`ImagePullBackOff`.

The chosen secret is written into the values file under
`global.dockerPullSecret` (or removed from it, with `--no-pull-secret`).

---

## What `kcli mirror` writes

`kcli mirror` does not generate any new files in the chart directory.
Instead, it edits the `--values` file you passed in **in place** and
writes a timestamped backup of the original next to it:

```
my-values.yaml                       # ← rewritten in place
my-values.yaml.bak.20260504T000015Z  # ← byte-for-byte copy of the
                                     #   pre-rewrite original
```

The rewritten values file is what you pass to the chart install per the
**Cortex Cloud portal** instructions for your tenant. To roll back, simply
move the backup over the rewritten file:

```bash
mv my-values.yaml.bak.20260504T000015Z my-values.yaml
```

---

## Environment variables

| Variable                | Default     | Purpose                                                          |
|-------------------------|-------------|------------------------------------------------------------------|
| `NO_COLOR`              | _(unset)_   | Disable ANSI colors when set to a non-empty value                |
| `DOCKER_CONFIG`         | `~/.docker` | Standard Docker config-dir override                              |
| `TMPDIR`                | `/tmp`      | Override scratch directory                                       |
| `KCLI_SKIP_VERSION_CHECK`| _(unset)_  | Bypass the mandatory upstream-version check (see [Staying current](#staying-current-mandatory-version-check)) |

---

## Exit codes

| Code  | Meaning                                                                   |
|-------|---------------------------------------------------------------------------|
| `0`   | Success.                                                                  |
| `1`   | Runtime failure (unsupported bundle version, push failures, missing prereq, …). |
| `64`  | Usage error — bad flags, missing required arguments. (`EX_USAGE`.)        |
| `65`  | Mandatory upstream-version check failed (local script is stale; see [Staying current](#staying-current-mandatory-version-check)). |
| `130` | Interrupted by `SIGINT` / `SIGTERM`.                                      |

---

## Logging & diagnostics

Each invocation writes a structured audit log to
`$TMPDIR/kcli-log-XXXXXX.log`. The log is preserved across runs (success
*and* failure) so you can always attach it to support tickets; on a
non-zero exit its path is also surfaced in a `[WARN]` line.

For verbose debugging, run with `bash -x`:

```bash
bash -x ./tools/kcli/kcli mirror …
```

---

## Security notes

- **No secrets are persisted by `kcli` itself.** The dockerPullSecret
  material is held only in shell variables and the values file (which
  lives where the operator chose to keep it). The audit log contains
  only metadata, never credentials.
- **Strict input validation.** Registry strings are bounded to a safe
  character class (`[A-Za-z0-9._/:@-]`) and rejected outright if they
  contain shell-injection-like sequences.
- **Bundle gate.** Older / unrecognised bundle versions are rejected
  before any registry traffic.
- **Backup before mutation.** A timestamped `.bak` copy of the values
  file is always written before the in-place rewrite — destructive edits
  are reversible.
- **Cleanup on failure.** `EXIT`, `INT`, and `TERM` traps remove
  temporary scratch space even when interrupted. The values-file rewrite
  is staged into a sibling temp file and committed via an atomic `mv`,
  so on any failure the original file is left untouched and the
  pre-rewrite `.bak` copy remains alongside it.

---

## License

Licensed under the [Apache License, Version 2.0](LICENSE).
