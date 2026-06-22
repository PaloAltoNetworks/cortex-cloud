#!/usr/bin/env bash
# purge-smoke-test.sh — end-to-end smoke test for `kcli purge`.
#
# Spins up a throwaway kind cluster, plants a representative set of
# labeled resources across the cluster (including a CRD instance, to
# prove the all-API-groups sweep works), then runs `kcli purge` and
# asserts the cluster is fully clean afterwards.
#
# Three scenarios are exercised in sequence:
#
#   1) Happy path
#      The chart is installed with default values (namespace = panw),
#      `kcli purge --yes --delete-namespace` runs, and the assertions
#      confirm zero remaining labeled resources AND no namespace.
#
#   2) Corrupted-helm path
#      Same install, but BEFORE purge we delete the Helm release
#      secret (sh.helm.release.v1.*). This makes `helm uninstall`
#      fail — proving purge's contract that helm failures are
#      non-fatal and resource cleanup still completes.
#
#   3) CRD-instance path
#      A simple CRD + a custom resource are installed and labeled
#      with author=pan. Purge MUST find and delete the CR even though
#      it lives in a non-core API group.
#
# Requires: kind, kubectl, helm 3.8+, jq, the kcli script at
#           ../kcli (relative to this file).
#
# Usage:
#     bash tools/kcli/examples/purge-smoke-test.sh
#
# The script always tries to delete the kind cluster at exit (EXIT trap)
# so a failed assertion doesn't strand a cluster on your machine.

set -Eeuo pipefail

# bash 4.0+ is required (mapfile, ${var,,} are bash-4 features). macOS
# ships bash 3.2 as /bin/bash, so invoking via `bash script.sh` from a
# default shell picks the wrong interpreter even though the shebang
# above is `/usr/bin/env bash`. Fail loudly with a fix.
if (( BASH_VERSINFO[0] < 4 )); then
  echo "purge-smoke-test.sh requires bash 4.0+ (you have $BASH_VERSION)." >&2
  case "$(uname -s 2>/dev/null)" in
    Darwin)
      echo "macOS ships bash 3.2 at /bin/bash. Install bash 4+ with:" >&2
      echo "    brew install bash" >&2
      echo "Then either:" >&2
      echo "    /opt/homebrew/bin/bash examples/purge-smoke-test.sh" >&2
      echo "or just run the script directly so the shebang is used:" >&2
      echo "    ./examples/purge-smoke-test.sh" >&2
      ;;
    *)
      echo "Install bash 4+ via your distro's package manager and run" >&2
      echo "the script directly so the '/usr/bin/env bash' shebang is used." >&2
      ;;
  esac
  exit 1
fi

# ─── Configuration ──────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KCLI_BIN="${SCRIPT_DIR}/../kcli"
KIND_CLUSTER="kcli-purge-smoke"
NAMESPACE="panw"
LABEL_SELECTOR="app.kubernetes.io/author=pan"

# Skip the upstream version check — this script may run against a
# local-only branch of kcli that isn't yet on main.
export KCLI_SKIP_VERSION_CHECK=1

# ─── Skip-list synchronization ──────────────────────────────────────────────
# Parse PURGE_SKIP_RESOURCES out of kcli so assert_clean's skip set
# stays in sync automatically.
load_skip_list_from_kcli() {
  awk '
    /^readonly -a PURGE_SKIP_RESOURCES=\(/ { inside = 1; next }
    inside && /^\)/ { inside = 0; exit }
    inside { print }
  ' "$KCLI_BIN" | tr -d '"' | tr -s '[:space:]' '\n' | sed '/^$/d'
}
mapfile -t SKIP_RESOURCES < <(load_skip_list_from_kcli)
if (( ${#SKIP_RESOURCES[@]} == 0 )); then
  echo "[SMOKE] WARN: could not parse PURGE_SKIP_RESOURCES from kcli;" \
       "falling back to hardcoded list." >&2
  SKIP_RESOURCES=(
    events events.events.k8s.io bindings componentstatuses
    tokenreviews subjectaccessreviews selfsubjectaccessreviews
    selfsubjectrulesreviews localsubjectaccessreviews
  )
fi

# ─── Output helpers ─────────────────────────────────────────────────────────
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; CYAN=$'\033[0;36m'; NC=$'\033[0m'
info()  { printf '%s[SMOKE]%s %s\n' "$CYAN"  "$NC" "$*"; }
pass()  { printf '%s[PASS]%s  %s\n' "$GREEN" "$NC" "$*"; }
fail()  { printf '%s[FAIL]%s  %s\n' "$RED"   "$NC" "$*" >&2; exit 1; }

# ─── Lifecycle ──────────────────────────────────────────────────────────────
cleanup() {
  local rc=$?
  info "Tearing down kind cluster: $KIND_CLUSTER"
  kind delete cluster --name "$KIND_CLUSTER" >/dev/null 2>&1 || true
  exit "$rc"
}
trap cleanup EXIT

require_tool() {
  command -v "$1" >/dev/null 2>&1 \
    || fail "Required tool not on PATH: $1"
}

# ─── Pre-flight ─────────────────────────────────────────────────────────────
info "Checking prerequisites…"
for tool in kind kubectl helm jq bash; do
  require_tool "$tool"
done
[[ -x "$KCLI_BIN" ]] || fail "kcli not executable at $KCLI_BIN"
info "All prerequisites present."

# ─── Spin up kind cluster ───────────────────────────────────────────────────
info "Creating kind cluster: $KIND_CLUSTER"
kind delete cluster --name "$KIND_CLUSTER" >/dev/null 2>&1 || true
kind create cluster --name "$KIND_CLUSTER" --wait 60s >/dev/null

# ─── Helper: install a representative set of labeled resources ─────────────
# We don't actually need the full konnector chart for this test — we
# only need enough resources, spread across enough API groups, that
# the all-groups sweep has something meaningful to find. The objects
# below mirror what the chart ships (configmap / secret / sa / role /
# rolebinding / clusterrole / clusterrolebinding) plus a CRD instance.
plant_labeled_resources() {
  local ns="$1"
  info "Planting labeled resources in namespace: $ns"

  # If a previous scenario put the namespace into Terminating, wait
  # for it to fully reap before re-creating — Kubernetes refuses any
  # create call against a Terminating ns.
  if kubectl get ns "$ns" >/dev/null 2>&1; then
    local i
    for i in $(seq 1 60); do
      local phase
      phase=$(kubectl get ns "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || true)
      [[ "$phase" != "Terminating" ]] && break
      sleep 1
    done
  fi
  kubectl create namespace "$ns" >/dev/null 2>&1 || true

  # Core/v1 + rbac.authorization.k8s.io examples.
  kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: smoke-config
  namespace: $ns
  labels: { app.kubernetes.io/author: pan }
data:
  hello: "world"
---
apiVersion: v1
kind: Secret
metadata:
  name: smoke-secret
  namespace: $ns
  labels: { app.kubernetes.io/author: pan }
type: Opaque
stringData: { token: smoke }
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: smoke-sa
  namespace: $ns
  labels: { app.kubernetes.io/author: pan }
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: smoke-role
  namespace: $ns
  labels: { app.kubernetes.io/author: pan }
rules:
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get","list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: smoke-clusterrole
  labels: { app.kubernetes.io/author: pan }
rules:
  - apiGroups: [""]
    resources: ["nodes"]
    verbs: ["get","list"]
EOF
}

# ─── Helper: install a CRD + a labeled CR instance ──────────────────────────
# This is the all-API-groups proof: a fresh, custom group that didn't
# exist when kcli was written must still be picked up by discovery.
plant_crd_instance() {
  info "Planting CRD + labeled custom resource (group: smoke.kcli.test)"
  kubectl apply -f - >/dev/null <<'EOF'
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: smokes.smoke.kcli.test
spec:
  group: smoke.kcli.test
  scope: Namespaced
  names:
    plural: smokes
    singular: smoke
    kind: Smoke
    shortNames: ["sk"]
  versions:
    - name: v1
      served: true
      storage: true
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              properties:
                msg: { type: string }
EOF

  # The CRD takes a moment to become Established — wait for it.
  kubectl wait --for=condition=Established \
    crd/smokes.smoke.kcli.test --timeout=30s >/dev/null

  kubectl apply -f - >/dev/null <<EOF
apiVersion: smoke.kcli.test/v1
kind: Smoke
metadata:
  name: smoke-instance
  namespace: $NAMESPACE
  labels: { app.kubernetes.io/author: pan }
spec: { msg: "hello purge" }
EOF
}

# ─── Helper: assert zero labeled resources remain ───────────────────────────
# Sweeps every API group the same way kcli does and asserts an empty
# result. Uses the SKIP_RESOURCES array (loaded from kcli at script
# start) so the skip set stays in sync with the production code path.
# If the assertion fails we print the offending rows so the test
# output is self-explanatory.
assert_clean() {
  local context="$1"
  info "Verifying cluster is clean (context: $context)…"

  local rows=""
  local resource is_skipped skipped
  while IFS= read -r resource; do
    [[ -z "$resource" ]] && continue
    is_skipped=false
    for skipped in "${SKIP_RESOURCES[@]}"; do
      if [[ "$resource" == "$skipped" ]]; then
        is_skipped=true
        break
      fi
    done
    $is_skipped && continue
    local out
    out=$(kubectl get "$resource" -A -l "$LABEL_SELECTOR" \
            -o json --ignore-not-found 2>/dev/null \
          | jq -r '
              .items // []
              | .[]
              | "\(.kind)\t\(.metadata.namespace // "-")\t\(.metadata.name)"
            ' 2>/dev/null || true)
    [[ -n "$out" ]] && rows="${rows}${out}"$'\n'
  done < <(
    kubectl api-resources --verbs=list --namespaced=true \
      -o name --no-headers 2>/dev/null
    kubectl api-resources --verbs=list --namespaced=false \
      -o name --no-headers 2>/dev/null
  )

  rows="${rows%$'\n'}"
  if [[ -n "$rows" ]]; then
    fail "Labeled resources remain after purge (context=$context):"$'\n'"$rows"
  fi
  pass "Cluster is clean ($context)."
}

# ─── Helper: count how many labeled resources are currently present ─────────
# Used by the dry-run scenario to prove --dry-run is non-destructive.
count_labeled_resources() {
  local total=0 out count resource is_skipped skipped
  while IFS= read -r resource; do
    [[ -z "$resource" ]] && continue
    is_skipped=false
    for skipped in "${SKIP_RESOURCES[@]}"; do
      if [[ "$resource" == "$skipped" ]]; then
        is_skipped=true
        break
      fi
    done
    $is_skipped && continue
    out=$(kubectl get "$resource" -A -l "$LABEL_SELECTOR" \
            -o json --ignore-not-found 2>/dev/null \
          | jq -r '.items // [] | length' 2>/dev/null || echo 0)
    count=${out:-0}
    total=$((total + count))
  done < <(
    kubectl api-resources --verbs=list --namespaced=true \
      -o name --no-headers 2>/dev/null
    kubectl api-resources --verbs=list --namespaced=false \
      -o name --no-headers 2>/dev/null
  )
  printf '%d\n' "$total"
}

# ─── Helper: invoke kcli purge non-interactively ────────────────────────────
# `--yes` skips the confirmation prompts. The smoke test is the one
# place where we WANT --yes to be effective, so we deliberately do not
# use a context name that contains "prod".
run_purge() {
  local extra_args=("$@")
  info "Running: kcli purge --namespace $NAMESPACE --yes ${extra_args[*]}"
  "$KCLI_BIN" purge \
    --namespace "$NAMESPACE" \
    --yes \
    "${extra_args[@]}"
}

# ─── Scenario 1 — Happy path ────────────────────────────────────────────────
info "─────── SCENARIO 1: happy path ───────"
plant_labeled_resources "$NAMESPACE"
helm_namespace_existed=true

# Install a stub helm release so helm uninstall has something to do.
# We use a literal stub chart in /tmp rather than fetching the real
# konnector chart — the point of the test is purge, not helm itself.
stub_chart_dir=$(mktemp -d)
mkdir -p "$stub_chart_dir/templates"
cat > "$stub_chart_dir/Chart.yaml" <<'EOF'
apiVersion: v2
name: konnector
version: 0.0.1
EOF
cat > "$stub_chart_dir/templates/cm.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: helm-stub-cm
  namespace: $NAMESPACE
  labels: { app.kubernetes.io/author: pan }
data:
  stub: "yes"
EOF
helm upgrade --install k8s-connector-release "$stub_chart_dir" \
  -n "$NAMESPACE" --create-namespace >/dev/null

run_purge --delete-namespace

# Namespace must be gone. kcli uses --wait=false for the namespace
# delete (it returns as soon as the API server accepts the request)
# so the actual reap is asynchronous — wait up to 60s for the
# namespace to leave Terminating state.
info "Waiting for namespace $NAMESPACE to finish terminating…"
for _ in $(seq 1 60); do
  kubectl get ns "$NAMESPACE" >/dev/null 2>&1 || break
  sleep 1
done
if kubectl get ns "$NAMESPACE" >/dev/null 2>&1; then
  fail "Namespace $NAMESPACE still exists 60s after --delete-namespace."
fi
pass "Namespace $NAMESPACE was deleted."

# Cluster-scoped labeled resources must be gone too.
assert_clean "scenario 1"

# ─── Scenario 2 — Corrupted-helm path ───────────────────────────────────────
info "─────── SCENARIO 2: corrupted helm release ───────"
plant_labeled_resources "$NAMESPACE"
helm upgrade --install k8s-connector-release "$stub_chart_dir" \
  -n "$NAMESPACE" --create-namespace >/dev/null

# Corrupt the release by removing its release secret. After this,
# `helm uninstall` will error — and purge must continue regardless.
info "Corrupting helm release: deleting sh.helm.release.v1.* secret"
kubectl -n "$NAMESPACE" delete secret \
  -l owner=helm,name=k8s-connector-release \
  --ignore-not-found >/dev/null

run_purge --delete-namespace
assert_clean "scenario 2 (corrupted helm)"

# ─── Scenario 3 — CRD-instance path ─────────────────────────────────────────
info "─────── SCENARIO 3: CRD instance is swept ───────"
plant_labeled_resources "$NAMESPACE"
plant_crd_instance

# Sanity check: the CR exists before purge.
if ! kubectl get smokes.smoke.kcli.test \
       -n "$NAMESPACE" smoke-instance >/dev/null 2>&1; then
  fail "Setup error: CR smoke-instance was not created."
fi

run_purge

# The CR (under the custom group) must be gone — the proof that the
# all-API-groups sweep works for kinds kcli was never compiled with.
if kubectl get smokes.smoke.kcli.test \
     -n "$NAMESPACE" smoke-instance >/dev/null 2>&1; then
  fail "CR smoke-instance survived purge (CRD sweep is broken)."
fi
pass "CR smoke-instance was deleted via the all-API-groups sweep."
assert_clean "scenario 3 (CRD instance)"

# ─── Scenario 4 — Node annotation strip ─────────────────────────────────────
# Konnector writes annotations under paloaltonetworks.com/* onto Node
# objects. Nodes never carry author=pan (they pre-date the install)
# so the main label sweep can't reach the annotations.
#
# Scenarios are NOT independent: each assumes the previous cluster
# state. Reordering requires re-checking namespace preconditions.
info "─────── SCENARIO 4: node-annotation strip ───────"

# Annotate every node with two paloaltonetworks.com/* keys. Also add a
# control annotation (other.example.com/keep=yes) that purge MUST NOT
# touch — proves the prefix match is strict.
info "Annotating nodes with paloaltonetworks.com/* + a control key…"
for node in $(kubectl get nodes -o name); do
  kubectl annotate "$node" --overwrite \
    paloaltonetworks.com/cluster-id=smoke-cluster-id \
    paloaltonetworks.com/scan-status=ok \
    other.example.com/keep=yes \
    >/dev/null
done

run_purge

# Assertion 1: every paloaltonetworks.com/* annotation is gone.
info "Verifying paloaltonetworks.com/* annotations are stripped…"
remaining=$(kubectl get nodes -o json \
  | jq -r '
      .items[]
      | (.metadata.annotations // {})
      | to_entries[]
      | select(.key | startswith("paloaltonetworks.com/"))
      | .key
    ')
if [[ -n "$remaining" ]]; then
  fail "paloaltonetworks.com/* annotations still present on nodes:"$'\n'"$remaining"
fi
pass "All paloaltonetworks.com/* annotations were stripped."

# Assertion 2: the control annotation survived (proves prefix matching
# is strict, not a substring or wildcard match).
info "Verifying control annotation 'other.example.com/keep' survived…"
control=$(kubectl get nodes -o json \
  | jq -r '
      [.items[]
       | (.metadata.annotations // {})
       | to_entries[]
       | select(.key == "other.example.com/keep")]
      | length
    ')
if [[ "$control" -lt 1 ]]; then
  fail "Control annotation other.example.com/keep was incorrectly stripped."
fi
pass "Control annotation other.example.com/keep survived ($control node(s))."

assert_clean "scenario 4 (node annotations)"

# ─── Scenario 5 — Dry-run is non-destructive ────────────────────────────────
# Prove --dry-run short-circuits before any mutating call.
info "─────── SCENARIO 5: --dry-run is non-destructive ───────"
plant_labeled_resources "$NAMESPACE"

# Re-annotate nodes (scenario 4 stripped them).
info "Re-annotating nodes with paloaltonetworks.com/* + a control key…"
for node in $(kubectl get nodes -o name); do
  kubectl annotate "$node" --overwrite \
    paloaltonetworks.com/cluster-id=dryrun-cluster-id \
    other.example.com/keep=yes \
    >/dev/null
done

count_panw_annotations() {
  kubectl get nodes -o json \
    | jq -r '
        [.items[]
         | (.metadata.annotations // {})
         | to_entries[]
         | select(.key | startswith("paloaltonetworks.com/"))]
        | length
      '
}

before_count=$(count_labeled_resources)
before_panw_ann=$(count_panw_annotations)
info "  before: labeled=$before_count  panw-annotations=$before_panw_ann"
(( before_count > 0 ))    || fail "Setup: expected labeled resources before --dry-run."
(( before_panw_ann > 0 )) || fail "Setup: expected paloaltonetworks.com/* annotations before --dry-run."

run_purge --dry-run

after_count=$(count_labeled_resources)
after_panw_ann=$(count_panw_annotations)
info "  after:  labeled=$after_count   panw-annotations=$after_panw_ann"

(( after_count == before_count )) \
  || fail "--dry-run mutated labeled resources: before=$before_count after=$after_count"
(( after_panw_ann == before_panw_ann )) \
  || fail "--dry-run mutated node annotations: before=$before_panw_ann after=$after_panw_ann"
pass "--dry-run was non-destructive."

# Real purge to leave the cluster clean.
info "Cleaning up scenario 5 with a real purge…"
run_purge --delete-namespace
assert_clean "scenario 5 (post dry-run cleanup)"

# ─── Done ────────────────────────────────────────────────────────────────────
echo ""
pass "All five purge scenarios passed against kind cluster '$KIND_CLUSTER'."
