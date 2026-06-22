# Cortex Cloud Konnector — CLI (`kcli`)

`kcli` has two subcommands:

| Command | What it does |
|---|---|
| [`kcli mirror`](#how-kcli-fits-with-the-portal-install-wizard) | Mirror konnector images from the Cortex source registry into your private registry and rewrite `values.yaml` in place. |
| [`kcli purge`](#purge--corrupted-environment-recovery) | **"Real delete"** for corrupted/orphaned installs: best-effort `helm uninstall` followed by an across-all-API-groups cleanup of every resource carrying `app.kubernetes.io/author=pan`. |

`kcli mirror` does three things, in order:

1. **Pulls** every konnector image from the Cortex source registry (multi-arch).
2. **Pushes** them to your private registry.
3. **Rewrites** your `values.yaml` in place (with a timestamped `.bak`) so the chart points at the mirror.

That's it. You then run the portal's unchanged `helm upgrade --install` against the rewritten file. `kcli` never runs `helm install` itself — the portal command stays the source of truth for release name, namespace, and tenant flags, and is frequently delivered through GitOps (Argo CD, Flux).

---

## Quick Start

```bash
# 1. In the Cortex portal, download values.yaml + auth.json. Do NOT run the
#    portal's "helm registry login + helm upgrade --install" block yet.

# 2. Log in to your private (target) registry.
docker login myregistry.azurecr.io

# 3. Mirror images and rewrite values.yaml in place.
kcli mirror \
  --chart-version 2.0.0 \
  --values ./values.yaml \
  --private-registry myregistry.azurecr.io/cortex \
  --docker-pull-secret-file ./pull-secret.dockerconfigjson

# 4. Run the portal's `helm registry login && helm upgrade --install` block,
#    unchanged, against the rewritten values.yaml.

# (Recovery) Broken / orphaned install? Preview first, then purge.
kcli purge --dry-run
kcli purge   # see Purge section for --force / --delete-namespace / etc.
```

Need a kubelet-compatible `pull-secret.dockerconfigjson`? See [Pull Secrets](#pull-secrets-what-kubelet-accepts) — this is the #1 source of `ImagePullBackOff` and you should read it before step 3.

---

## Table of Contents

- [How `kcli` fits with the portal install wizard](#how-kcli-fits-with-the-portal-install-wizard)
- [Prerequisites](#prerequisites)
- [Install](#install)
- [Usage](#usage)
  - [Step 1 — Download the values file](#step-1--download-the-values-file)
  - [Step 2 — Mirror images](#step-2--mirror-images)
  - [Step 3 — Install the konnector](#step-3--install-the-konnector)
- [Pull Secrets: What `kubelet` Accepts](#pull-secrets-what-kubelet-accepts)
- [Purge — corrupted-environment recovery](#purge--corrupted-environment-recovery)
- [Command Reference](#command-reference)
- [What `kcli` does NOT do](#what-kcli-does-not-do)
- [Staying Current](#staying-current)
- [Troubleshooting](#troubleshooting)
- [Examples](#examples)
- [License](#license)

---

## How `kcli` fits with the portal install wizard

The Cortex Cloud portal's Kubernetes connect wizard has two sections: **(a)** **Download Configuration Files** (`values.yaml` + `auth.json`), and **(b)** **Run Installation Commands** (a single block pairing `helm registry login` with `helm upgrade --install`).

`kcli` slots in between **(a)** and **(b)**:

| Step | Where it runs | What you do |
|------|---------------|-------------|
| 1. Portal wizard, section (a) | Workstation | Download `values.yaml` / `auth.json` from the portal. **Stop there** — don't run the install commands yet. |
| 2. `kcli mirror` | Workstation with access to both registries | Mirror images to your private registry and rewrite `values.yaml` in place. |
| 3. Portal wizard, section (b) | Cluster admin host (or GitOps) | Run the wizard's `helm registry login` + `helm upgrade --install` block, **unchanged**, against the rewritten values file. |

> `kcli mirror` handles the **source-registry** login itself, using credentials already inside `values.yaml`. You do not need to run the wizard's `helm registry login` before mirroring — only before the install in Step 3.

---

## Prerequisites

| Tool | Minimum Version | Purpose |
|------|-----------------|---------|
| **bash** | 4.0+ | Script runtime (see macOS note below) |
| **docker** | 20.10+ with `buildx` | Pull/push multi-arch images |
| **yq** | v4 (mikefarah/yq) | YAML processing |
| **jq** | 1.6+ | JSON processing |
| **curl** | any recent | Chart download + version check |
| **helm** | 3.8+ | Pull the chart from the source OCI registry (only with `--chart-version`) |
| `tar`, `base64` | POSIX | Bundled with every supported OS |

> **macOS ships bash 3.2.** Install a newer one with `brew install bash` — no shell change needed; `kcli`'s `/usr/bin/env bash` shebang will pick up Homebrew's bash if it's first on `PATH`.

> **yq must be the Go-based mikefarah/yq**, not the Python one. Check with `yq --version`.

> The machine running `kcli` needs access to both the Cortex source registry and your private registry. The cluster only needs access to your private registry.

> `kcli mirror` requires **konnector bundle v2 or higher**. Older bundles are rejected up front.

> Air-gapped? Set `KCLI_SKIP_VERSION_CHECK=1` to skip the upstream version check (see [Staying Current](#staying-current)).

---

## Install

`kcli` is a single self-contained bash script. Pin to a tag for reproducible installs:

```bash
curl -fsSL \
  "https://raw.githubusercontent.com/PaloAltoNetworks/cortex-cloud/main/tools/kcli/kcli" \
  -o /tmp/kcli
sudo install -m 0755 /tmp/kcli /usr/local/bin/kcli
kcli version
```

Or clone the repo and symlink `tools/kcli/kcli` into your `PATH`.

---

## Usage

### Step 1 — Download the values file

In the Cortex Cloud portal, generate an installation bundle and download its files. **You will stop partway through the wizard** — see the [hand-off table](#how-kcli-fits-with-the-portal-install-wizard).

1. **Settings → Data Sources & Integrations**
   ![Cortex Settings](docs/images/cortex-settings-menu.png)
2. Click **Kubernetes**
   ![Kubernetes tile](docs/images/cortex-data-sources-kubernetes.png)
3. **Edit Profile** → set Profile Name `Standalone-Installer`, disable Auto Upgrade, **Apply**
   ![Edit Profile](docs/images/cortex-edit-profile-settings.png)
4. **Generate**, then in the **Connect Kubernetes** wizard:

   ![Connect wizard](docs/images/cortex-kubernetes-connect-wizard.png)

   - ✅ Download both `values.yaml` and `auth.json` to the workstation where you'll run `kcli`.
   - 🛑 **Do not run** the "Run Installation Commands" block yet — copy it aside for Step 3.

See [`examples/values-example.yaml`](examples/values-example.yaml) for a fully commented template of the portal-issued values file.

---

### Step 2 — Mirror images

Log in to your **target** (private) registry first, then run `kcli mirror`:

```bash
docker login myregistry.azurecr.io

kcli mirror \
  --chart-version 2.0.0 \
  --values ./values.yaml \
  --private-registry myregistry.azurecr.io/cortex \
  --docker-pull-secret-file ./pull-secret.dockerconfigjson
```

`kcli` resolves the chart from `oci://<global.imageRegistry>/helm/konnector-bundle:<version>` (read from your values file) using the credentials already present in `values.yaml`. **You do not need to run the wizard's `helm registry login` for mirroring** — only for the install in Step 3.

If you've already downloaded a chart archive (for example on an air-gapped relay host), pass it instead:

```bash
kcli mirror \
  --chart ./konnector-2.0.0.tgz \
  --values ./values.yaml \
  --private-registry myregistry.azurecr.io/cortex \
  --docker-pull-secret-file ./pull-secret.dockerconfigjson
```

#### What changes in `values.yaml`

`kcli` writes a backup to `<values>.bak.YYYYMMDDTHHMMSSZ` and edits three things:

```diff
 global:
-  imageRegistry: us-central1-docker.pkg.dev/<src-proj>/<src-repo>
+  imageRegistry: myregistry.azurecr.io/cortex
-  dockerPullSecret: <source-registry-creds-b64>
+  dockerPullSecret: <your-private-registry-creds-b64>
   bundle:
     <component>:
       image:
-        repository: <src-repo>/<component>
+        repository: <component>
```

Commit the rewritten file if you're driving installs through GitOps.

#### Providing the pull secret

Exactly **one** of these is required — omitting all three is a hard error (we fail loudly to prevent a silent `ImagePullBackOff` at install time):

| Flag | When to use |
|------|-------------|
| `--docker-pull-secret-file <file>` | You have a `dockerconfigjson` file with **inline** credentials. See [Pull Secrets](#pull-secrets-what-kubelet-accepts). |
| `--docker-pull-secret <base64>` | You already have the secret base64-encoded. |
| `--no-pull-secret` | Cluster pulls without an inline secret. Two sub-cases — pick the right one: |
| &nbsp;&nbsp;• *managed identity* | IRSA, EKS Pod Identity, GKE Workload Identity, AKS Managed Identity — the node/pod auths to the registry implicitly. |
| &nbsp;&nbsp;• *out-of-band secret* | You will create an `imagePullSecret` resource in the cluster yourself (or via GitOps) before installing. **Don't forget this step** — it's the #1 cause of `ImagePullBackOff` when using `--no-pull-secret`. |

> ⚠️ **Do not pass `~/.docker/config.json` blindly.** It often delegates to a keychain or cloud CLI helper, which `kubelet` cannot use. See [Pull Secrets](#pull-secrets-what-kubelet-accepts).

#### Dry run

Preview without pulling/pushing or rewriting:

```bash
kcli mirror --chart-version 2.0.0 --values ./values.yaml \
  --private-registry myregistry.azurecr.io/cortex --dry-run
```

#### Roll back

```bash
mv values.yaml.bak.<TIMESTAMP> values.yaml
```

---

### Step 3 — Install the konnector

Run the portal wizard's **Run Installation Commands** block, unchanged. It contains:

1. `helm registry login ...` — logs into the source OCI registry the install pulls the chart from.
2. `helm upgrade --install ...` — installs the konnector against the values file `kcli mirror` rewrote, so pods pull images from your private registry.

Run them together as the wizard shows them — they're a single login + install pair.

---

## Pull Secrets: What `kubelet` Accepts

> Read this **before** Step 2 if you're using `--docker-pull-secret-file`. Almost every "it worked locally but the pods can't pull" report traces back to a credential helper here.

`kubelet` **cannot use Docker credential helpers** (`credsStore`, `credHelpers`, `osxkeychain`, `acr`, `gcloud`, `ecr-login`, etc.). It only understands inline credentials:

```json
{
  "auths": {
    "myregistry.azurecr.io": { "auth": "<base64(username:password)>" }
  }
}
```

Build one for your registry:

```bash
REG="myregistry.azurecr.io"
USER="<username>"          # ACR token name, GAR _json_key, robot account, etc.
PASS="<password-or-token>"
AUTH=$(printf '%s:%s' "$USER" "$PASS" | base64 | tr -d '\n')
cat > pull-secret.dockerconfigjson <<EOF
{"auths":{"$REG":{"auth":"$AUTH"}}}
EOF
```

Long-lived credential recipes per registry:

- **ACR:** [ACR token](https://learn.microsoft.com/azure/container-registry/container-registry-repository-scoped-permissions) with `pull` rights → `<token-name>:<token-password>`
- **GAR / GCR:** service account with `roles/artifactregistry.reader` → `_json_key:$(cat key.json)`
- **ECR:** prefer IRSA / EKS Pod Identity + `--no-pull-secret` (ECR tokens expire after 12h)
- **Harbor / Quay / Artifactory:** robot account `username:password`
- **Docker Hub:** [Personal Access Token](https://docs.docker.com/security/for-developers/access-tokens/) → `<username>:<PAT>`

> Delete `pull-secret.dockerconfigjson` after running `kcli mirror` — the credential is now in your values file under `global.dockerPullSecret`.

---

## Purge — corrupted-environment recovery

`kcli purge` is the escape hatch for clusters where the konnector install is broken, half-uninstalled, or has drifted in a way that ordinary `helm uninstall` can't fix. It is **not** the normal uninstall path — for a healthy install just run `helm uninstall` against the release the portal used.

### When to reach for `purge`

- `helm uninstall` reports success but resources are still in the cluster.
- The Helm release secret (`sh.helm.release.v1.*`) is missing or corrupted, so `helm uninstall` errors out before doing anything.
- You inherited a partially-installed cluster (multiple historical release names, leftover CRDs, etc.) and need to start clean.
- A previous `kcli purge` was interrupted and you need to finish the job.

### What `purge` does (in order)

1. **Prints a target banner** — kube-context name and cluster server URL — and asks you to confirm you're operating on the right cluster. **Always shown**, even with `--yes`.
2. **Best-effort `helm uninstall`** for both historical release names (`k8s-connector-release` *and* `konnector`) in the `--namespace` you supply (default: `panw`). Helm failures here are **non-fatal** — that is the whole point of purge, since a corrupted release state is precisely what you're trying to recover from. Outcomes are recorded in a `HELM SUMMARY` table.
3. **Sweeps every API group in the cluster — including any installed CRDs** — using two `kubectl api-resources` calls (one for namespaced, one for cluster-scoped) and per-kind `kubectl get -A -l app.kubernetes.io/author=pan -o json`. Discovery results are aggregated into a deduplicated `(apiVersion, kind, namespace, name)` table.
4. **Prints a full per-resource listing** grouped by `Group/Kind` (namespaced rows shown as `namespace/name`, cluster-scoped as bare `name`) plus a `Summary by Group/Kind` table and a grand total, then asks for a second, explicit `yes` before any delete happens. With `--dry-run`, steps 5–8 are skipped, but the node-annotation preview (step 6) is still printed so dry-run is a complete preview of every mutating phase.
5. **Deletes each row** by its fully-qualified type (`kind.group/name`) with `--ignore-not-found --wait=false`. Per-row outcomes land in a `PURGE SUMMARY` table.
6. **Strips every annotation prefixed `paloaltonetworks.com/` from every Node.** **Always runs**, even when the label sweep found nothing — node annotations live on `Node` objects that pre-date the install and therefore never carry the `author=pan` label, so the main sweep cannot reach them. A `NODE ANNOTATION SUMMARY` table reports per-node outcomes. The prefix is hard-coded; the strip step is strict (a control annotation like `other.example.com/keep` is **never** touched).
7. **`--force` second pass (optional)** — patches `metadata.finalizers=[]` on rows that survived the first delete and re-issues the delete. Requires a separate `yes` confirmation; bypasses controller-driven cleanup, so use with care.
8. **`--delete-namespace` (optional)** — drops the namespace itself once labeled resources are gone. Refused for `kube-system`, `kube-public`, `kube-node-lease`, and `default`. If the namespace contains workloads that do **not** carry the author label, you'll be warned and asked to confirm again. The "foreign workload" check uses `kubectl get all`, which only covers standard workload kinds (`Pod`, `Deployment`, `Service`, `Job`, `CronJob`, `ReplicaSet`, `StatefulSet`, `DaemonSet`, `ReplicationController`); ConfigMap/Secret/PVC/RBAC/CRD resources inside the namespace are NOT counted but ARE deleted with the namespace.

### Hardcoded contracts (no flags)

These knobs are deliberately not configurable — they reflect permanent properties of the konnector chart:

| Knob | Value | Why |
|---|---|---|
| Label selector | `app.kubernetes.io/author=pan` | Permanent ownership marker stamped on every chart resource by [`common.labels`](../../charts/konnector/templates/_helpers.tpl). |
| Releases uninstalled | `k8s-connector-release` **and** `konnector` | Both names exist in the wild; we always try both, idempotently. |
| Node annotation prefix stripped | `paloaltonetworks.com/` | Konnector writes annotations under this prefix onto `Node` objects (cluster-id, scan markers, etc.). Mirrors `AnnotationPrefix` in the konnector source; strict prefix match (does NOT touch unrelated keys). |
| Skipped API resources | `events`, `bindings`, `componentstatuses`, the `*subjectaccessreview*` family | Cannot be listed by label even in principle. |
| Protected namespaces | `kube-system`, `kube-public`, `kube-node-lease`, `default` | Control-plane namespaces; never deleted by `--delete-namespace`. |

### Quick start

```bash
# Standard recovery — interactive, default namespace (panw).
kcli purge

# Preview what would be deleted, without touching anything.
kcli purge --dry-run

# Non-interactive (CI / scripted recovery), also drop the namespace.
kcli purge --yes --delete-namespace

# Stuck on finalizers (typical for some CRDs).
kcli purge --force

# Custom namespace + non-default context.
kcli purge --namespace mykonnector --kube-context staging-east
```

### Safety rails

- The kube-context and cluster server URL are **always** printed and confirmed before any change.
- `kubectl cluster-info` is called pre-flight — if the cluster is unreachable, purge aborts before any destructive call.
- `--yes` is **downgraded to an interactive prompt** when the active context name matches `prod` / `production` (case-insensitive). Production fat-fingers are the highest-impact failure mode for this command.
- Every `helm` and `kubectl` invocation is mirrored verbatim — command line + stdout + stderr — into `$TMPDIR/kcli-log-XXXXXX.log`. Attach this to any support ticket.

### What purge does NOT touch

- Resources without the `app.kubernetes.io/author=pan` label.
- Anything in the protected namespaces above, **unless** those resources themselves carry the author label.
- Your kubeconfig, your Helm cache, or any local files.
- The Cortex source registry credentials in any values file.

### Recovery / rollback

There is no rollback for a delete — re-install the konnector from the portal (or your GitOps source of truth) once purge reports `[OK] Purge complete.`. The audit log retains a per-resource record of what was deleted.

---

## Command Reference

### `kcli mirror`

```
kcli mirror (--chart <chart.tgz> | --chart-version <version>) \
            --values <values-file> --private-registry <registry> \
            (--docker-pull-secret <b64> | --docker-pull-secret-file <file> | --no-pull-secret) \
            [--dry-run]
```

| Flag | Required | Description |
|------|----------|-------------|
| `--chart <chart.tgz>` | one of these | Local konnector Helm chart archive (bundle v2+) |
| `--chart-version <version>` | one of these | Pull the chart from `oci://<global.imageRegistry>/helm/konnector-bundle:<version>` (e.g. `2.0.0`). `<global.imageRegistry>` is read from `--values`. Requires `helm`. |
| `--values <file>` | ✅ | Tenant values YAML. **Rewritten in place** (with `.bak` backup) |
| `--private-registry <url>` | ✅ | Target registry (e.g. `myregistry.azurecr.io/proj/repo`) |
| `--docker-pull-secret <b64>` | one of these | Base64-encoded dockerconfigjson |
| `--docker-pull-secret-file <file>` | one of these | Path to dockerconfigjson (auto-encoded) |
| `--no-pull-secret` | one of these | Strip `global.dockerPullSecret` from values (managed identity or out-of-band secret) |
| `--dry-run` | — | Preview only — no pulls, pushes, or rewrites |
| `-h, --help` | — | Show command help |

### `kcli purge`

```
kcli purge [--namespace <ns>] [--kube-context <ctx>] \
           [--dry-run] [--yes] [--force] [--delete-namespace]
```

| Flag | Required | Description |
|------|----------|-------------|
| `--namespace <ns>` | — | Namespace for the helm uninstall + optional `--delete-namespace` step. Default: `panw`. Discovery itself is cluster-wide regardless of this flag. |
| `--kube-context <ctx>` | — | kubectl/helm context to target. Defaults to your current kubectl context. |
| `--dry-run` | — | Run helm + discovery, print what would be deleted, exit without deleting. |
| `--yes`, `-y` | — | Skip the interactive `yes` confirmation. Ignored — and downgraded to an interactive prompt — when the active context name matches `/prod/i`. |
| `--force` | — | Second pass: for any row that survived the first delete (typically blocked by a stuck finalizer), patch `metadata.finalizers=[]` and re-issue the delete. Requires its own confirmation. |
| `--delete-namespace` | — | Delete the `--namespace` itself after the labeled resources are gone. Refused for `kube-system`, `kube-public`, `kube-node-lease`, `default`. |
| `-h`, `--help` | — | Show command help. |

The purge label selector (`app.kubernetes.io/author=pan`) and the two Helm release names (`k8s-connector-release`, `konnector`) are **hardcoded contracts of the konnector chart** — they are not exposed as flags. See [Purge — corrupted-environment recovery](#purge--corrupted-environment-recovery).

### `kcli version` / `kcli help`

```bash
kcli version        # also: --version, -v
kcli help           # also: --help, -h
kcli mirror --help  # command-specific help
kcli purge  --help  # command-specific help
```

### Environment Variables

| Variable | Description |
|----------|-------------|
| `NO_COLOR` | Set to any value to disable ANSI colors |
| `DOCKER_CONFIG` | Docker config dir (default: `~/.docker`) |
| `TMPDIR` | Scratch dir for chart extraction and logs (default: `/tmp`) |
| `KCLI_SKIP_VERSION_CHECK` | Set to `1` to bypass the upstream version check (air-gapped) |

**Exit codes:** `0` success · `1` runtime failure · `64` usage error · `65` stale-version block · `130` interrupted.

---

## What `kcli` does NOT do

To set expectations explicitly, `kcli` will never:

- Run `helm install` / `helm upgrade` — that's the portal's command in Step 3.
- Create Kubernetes `Secret` resources in your cluster.
- Manage namespaces, RBAC, or cluster prerequisites (except via `kcli purge --delete-namespace`, which only deletes).
- Commit or push the rewritten `values.yaml` to Git — GitOps workflows must commit it themselves.
- Mutate anything outside `--values` (and its `.bak` sibling) on the workstation.
- Delete resources that don't carry the `app.kubernetes.io/author=pan` label, even during `purge`.

---

## Staying Current

Every `kcli` run (except `version` / `help`) compares the local `VERSION` to the canonical script on `main`. If older, `kcli` **fails fast** with an actionable message (exit `65`).

The check is best-effort and is skipped (with a `[WARN]`) when `curl` is missing, the fetch times out (5 s), or `KCLI_SKIP_VERSION_CHECK=1` is set.

To update:
- Installed via `curl`: re-run the install command (bump `KCLI_VERSION`).
- Installed via `git clone`: `git pull`.

---

## Troubleshooting

**"Unsupported bundle version"** — `kcli mirror` needs bundle v2+. Check with `tar -xzOf <chart.tgz> konnector-bundle/Chart.yaml | yq '.version'`. Get a v2+ chart from the portal.

**"Could not extract `global.imageRegistry` / `global.dockerPullSecret`"** — Your values file is missing these fields. The portal-issued file includes both — make sure you're not pointing at a hand-crafted file.

**Docker login failures** — Source registry creds come from `global.dockerPullSecret` (must be valid base64). For the target, run `docker login <your-registry>` first (non-interactively in CI).

**`ImagePullBackOff` after install** — Almost always one of:
1. You used `--docker-pull-secret-file` with a `~/.docker/config.json` that delegates to a credential helper. Build a proper inline secret per [Pull Secrets](#pull-secrets-what-kubelet-accepts).
2. You used `--no-pull-secret` but forgot to create the `imagePullSecret` resource (or your managed-identity binding is wrong).

**Multi-arch push failures** — `kcli` uses `docker buildx imagetools create` and falls back to single-arch `docker tag` + `push`. Ensure `docker buildx version` works and a builder exists: `docker buildx create --use`.

**Wrong `yq`** — Run `yq --version` — must show `mikefarah/yq` v4. Install: `brew install yq` (macOS) or see [mikefarah/yq install docs](https://github.com/mikefarah/yq#install).

**"A newer kcli version is available" (exit 65)** — Update per [Staying Current](#staying-current), or set `KCLI_SKIP_VERSION_CHECK=1` in air-gapped environments.

**Logs** — Each run writes `$TMPDIR/kcli-log-XXXXXX.log` (preserved on success and failure) — attach this to support tickets. For deep debugging: `bash -x /usr/local/bin/kcli mirror ...`.

---

## Examples

- [`examples/values-example.yaml`](examples/values-example.yaml) — fully commented template of the portal-issued values file.
- [`examples/purge-smoke-test.sh`](examples/purge-smoke-test.sh) — end-to-end smoke test for `kcli purge` (spins up a `kind` cluster, plants labeled resources including a CRD instance, and asserts purge cleans everything across all API groups).

---

## License

Licensed under the [Apache License, Version 2.0](LICENSE).
