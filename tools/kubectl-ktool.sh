#!/bin/bash
#
# kubectl-ktool: A kubectl plugin for the Konnector agent.

# --- CONFIGURATION ---
VERSION="v0.1.0"
GITHUB_USER="PaloAltoNetworks"
GITHUB_REPO="cortex-cloud"
# The path to the script within the GitHub repository.
GITHUB_SCRIPT_PATH="tools/kubectl-ktool.sh"


# --- Helper Functions ---
error() {
    echo "Error: $1" >&2
    exit 1
}

WARN() {
    echo -e "\033[33mWarning:\033[0m $1" >&2
}

usage() {
    echo "Usage: kubectl ktool <command> [options]" >&2
    echo "Commands: collect-logs, upgrade, version" >&2
    exit 1
}


# --- Automatic Update Check Logic ---
check_for_updates() {
    local script_source_url="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/ktool/${GITHUB_SCRIPT_PATH}"
    
    local LATEST_VERSION_CONTENT
    LATEST_VERSION_CONTENT=$(curl --max-time 2 -fsSL "${script_source_url}" 2>/dev/null)

    if [ -z "$LATEST_VERSION_CONTENT" ]; then
        return
    fi
    
    local LATEST_VERSION
    LATEST_VERSION=$(echo "$LATEST_VERSION_CONTENT" | grep '^VERSION=' | sed -E 's/VERSION="([^"]+)"/\1/')

    if [ -z "$LATEST_VERSION" ] || [ "$VERSION" == "$LATEST_VERSION" ]; then
        return
    fi

    WARN "A new version (${LATEST_VERSION}) is available. Please run 'kubectl ktool upgrade' to update."
}


# --- Upgrade Command Logic ---
handle_upgrade() {
    echo "Current version: ${VERSION}"
    
    local script_source_url="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/ktool/${GITHUB_SCRIPT_PATH}"
    local TMP_FILE="/tmp/kubectl-ktool.new.$$"

    echo "Fetching latest version from ktool branch..."
    if ! curl -fsSL "${script_source_url}" -o "${TMP_FILE}"; then
        error "Could not download the latest script from the 'ktool' branch."
        rm -f "${TMP_FILE}"
        exit 1
    fi

    LATEST_VERSION=$(grep '^VERSION=' "${TMP_FILE}" | sed -E 's/VERSION="([^"]+)"/\1/')

    if [ -z "$LATEST_VERSION" ]; then
        error "Could not determine the latest version from the 'ktool' branch."
        rm -f "${TMP_FILE}"
        exit 1
    fi

    echo "Latest version available: ${LATEST_VERSION}"
    if [ "$VERSION" == "$LATEST_VERSION" ]; then
        echo "You are already using the latest version."
        rm -f "${TMP_FILE}"
        exit 0
    fi

    INSTALL_PATH=$(which kubectl-ktool)
    if [ -z "$INSTALL_PATH" ]; then
        error "Could not determine the installation path of 'kubectl-ktool'."
        rm -f "${TMP_FILE}"
        exit 1
    fi

    chmod +x "${TMP_FILE}"

    if [[ -w "$(dirname "$INSTALL_PATH")" ]]; then
        mv "${TMP_FILE}" "${INSTALL_PATH}"
    elif command -v sudo &> /dev/null; then
        sudo mv "${TMP_FILE}" "${INSTALL_PATH}"
    else
        error "Cannot write to ${INSTALL_PATH}. Please run upgrade command with sudo."
        rm -f "${TMP_FILE}"
        exit 1
    fi
    echo "Upgrade complete to version ${LATEST_VERSION}."
}


# --- Version Command Logic ---
handle_version() {
    echo "${VERSION}"
}


# --- Collect Logs Logic (Fully Implemented) ---
collect_logs() {
    NAMESPACE="pan"
    shift
    while [[ "$#" -gt 0 ]]; do
        case $1 in
            -n|--namespace) NAMESPACE="$2"; shift; shift;;
            *) error "Unknown option for collect-logs: $1";;
        esac
    done

    HELM_RELEASE_1="konnector"
    HELM_RELEASE_2="k8s-connector-manager"
    BUNDLE_DIR="konnector-support-bundle-${NAMESPACE}-$(date +%Y%m%d-%H%M%S)"
    
    echo "Starting support bundle collection for namespace: ${NAMESPACE}"
    echo "Output will be saved to ${BUNDLE_DIR}.tar.gz"

    mkdir -p "${BUNDLE_DIR}"

    # Helper for collecting command output
    collect_cmd() {
        local title="$1"
        local cmd="$2"
        local file="$3"
        echo "  -> Collecting ${title}..."
        bash -c "$cmd" > "${BUNDLE_DIR}/${file}" 2>&1
    }

    # 1. Cluster Info
    echo "[1/6] Collecting Cluster Information..."
    mkdir -p "${BUNDLE_DIR}/cluster-info"
    collect_cmd "Kubernetes version" "kubectl version" "cluster-info/version.txt"
    collect_cmd "Node details" "kubectl get nodes -o wide" "cluster-info/nodes.txt"

    # 2. Namespace Info
    echo "[2/6] Collecting Namespace Information..."
    mkdir -p "${BUNDLE_DIR}/namespace-info"
    collect_cmd "Events in namespace" "kubectl get events -n ${NAMESPACE} --sort-by='.lastTimestamp'" "namespace-info/events.txt"

    # 3. Helm Info
    echo "[3/6] Collecting Helm Release Information..."
    mkdir -p "${BUNDLE_DIR}/helm"
    collect_cmd "Helm status for ${HELM_RELEASE_1}" "helm status ${HELM_RELEASE_1} -n ${NAMESPACE}" "helm/status-${HELM_RELEASE_1}.txt"
    collect_cmd "Helm values for ${HELM_RELEASE_1}" "helm get values ${HELM_RELEASE_1} -n ${NAMESPACE} -a" "helm/values-${HELM_RELEASE_1}.yaml"
    collect_cmd "Helm status for ${HELM_RELEASE_2}" "helm status ${HELM_RELEASE_2} -n ${NAMESPACE}" "helm/status-${HELM_RELEASE_2}.txt"
    collect_cmd "Helm values for ${HELM_RELEASE_2}" "helm get values ${HELM_RELEASE_2} -n ${NAMESPACE} -a" "helm/values-${HELM_RELEASE_2}.yaml"

    # 4. Workload Status & Descriptions
    echo "[4/6] Collecting Workload Statuses..."
    mkdir -p "${BUNDLE_DIR}/workloads"
    collect_cmd "All workloads (wide)" "kubectl get all -n ${NAMESPACE} -o wide" "workloads/get-all-wide.txt"
    collect_cmd "All workloads (yaml)" "kubectl get all -n ${NAMESPACE} -o yaml" "workloads/get-all.yaml"
    
    echo "  -> Describing all workloads..."
    for kind in pod deployment statefulset daemonset service configmap replicaset ingress; do
        RESOURCES=$(kubectl get "$kind" -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
        if [ -n "$RESOURCES" ]; then
            mkdir -p "${BUNDLE_DIR}/workloads/${kind}"
            for name in $RESOURCES; do
                collect_cmd "${kind}/${name}" "kubectl describe ${kind} ${name} -n ${NAMESPACE}" "workloads/${kind}/${name}.describe.txt"
            done
        fi
    done

    # 5. Pod Logs
    echo "[5/6] Collecting Pod Logs..."
    mkdir -p "${BUNDLE_DIR}/logs"
    PODS=$(kubectl get pods -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
    for pod in $PODS; do
        CONTAINERS=$(kubectl get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.spec.containers[*].name} {.spec.initContainers[*].name}' 2>/dev/null)
        for container in $CONTAINERS; do
            collect_cmd "Logs for ${pod}/${container}" "kubectl logs ${pod} -c ${container} -n ${NAMESPACE}" "logs/${pod}_${container}.log"
            collect_cmd "Previous logs for ${pod}/${container}" "kubectl logs ${pod} -c ${container} -n ${NAMESPACE} --previous" "logs/${pod}_${container}.previous.log"
        done
    done

    # 6. Operator-Specific Info
    echo "[6/6] Collecting Operator Configurations..."
    mkdir -p "${BUNDLE_DIR}/operator"
    collect_cmd "Validating Webhooks" "kubectl get validatingwebhookconfigurations -l 'app.kubernetes.io/instance in (${HELM_RELEASE_1}, ${HELM_RELEASE_2})' -o yaml" "operator/validating-webhooks.yaml"
    collect_cmd "Mutating Webhooks" "kubectl get mutatingwebhookconfigurations -l 'app.kubernetes.io/instance in (${HELM_RELEASE_1}, ${HELM_RELEASE_2})' -o yaml" "operator/mutating-webhooks.yaml"
    # Add any CRD collections here, for example:
    # collect_cmd "MyCRD Instances" "kubectl get mycrds -n ${NAMESPACE} -o yaml" "operator/mycrds.yaml"
    
    # --- Packaging ---
    echo "Packaging support bundle..."
    tar -czf "${BUNDLE_DIR}.tar.gz" "${BUNDLE_DIR}"
    
    # --- Cleanup ---
    rm -rf "${BUNDLE_DIR}"

    echo "Support bundle created successfully: ${BUNDLE_DIR}.tar.gz"
}


# --- SCRIPT EXECUTION STARTS HERE ---

# Run the non-blocking update check for any command except 'upgrade'.
if [ "$1" != "upgrade" ]; then
    check_for_updates
fi

# --- MAIN COMMAND ROUTER ---
case "$1" in
    collect-logs)
        collect_logs "$@"
        ;;
    upgrade)
        handle_upgrade
        ;;
    version)
        handle_version
        ;;
    ""|-h|--help)
        usage
        ;;
    *)
        error "Unknown command '$1'"
        ;;
esac
