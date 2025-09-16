#!/bin/bash
#
# kubectl-ktool: A kubectl plugin for the Konnector agent.

# --- CONFIGURATION ---
VERSION="v1.1.0"
GITHUB_USER="PaloAltoNetworks"
GITHUB_REPO="cortex-cloud"
RELEASE_BRANCH="ktool"
GITHUB_SCRIPT_PATH="kubectl-ktool.sh"
SCRIPT_SOURCE_URL="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${RELEASE_BRANCH}/${GITHUB_SCRIPT_PATH}"


# --- Helper Functions ---
error() {
    echo "Error: $1" >&2
    exit 1
}

WARN() {
    echo -e "\033[33mWarning:\033[0m $1" >&2
}

# --- Detailed Usage Function ---
usage() {
    echo "Usage: kubectl ktool <command> [options]"
    echo
    echo "A tool for managing and collecting support data for the Konnector agent."
    echo
    echo "Commands:"
    echo "  collect-logs    Collects a comprehensive diagnostic support bundle."
    echo "  upgrade         Upgrades this tool to the latest version from GitHub."
    echo "  version         Prints the current version of this tool."
    echo
    echo "Options for 'collect-logs':"
    echo "  -n, --namespace <namespace>   The namespace where the agent is installed. (Default: pan)"
    echo "  --kubeconfig <path>           Path to a specific kubeconfig file to use."
    echo "  --context <context>           The name of the kubeconfig context to use."
    echo
    echo "Run 'kubectl ktool <command> --help' for more information on a specific command."
    exit 1
}


# --- Automatic Update Check Logic ---
check_for_updates() {
    local command_arg="$1"

    # Don't check for updates when running the upgrade command itself.
    if [[ "$command_arg" == "upgrade" ]]; then
        return
    fi

    # Increased timeout for better reliability on slower networks.
    local LATEST_VERSION_CONTENT
    LATEST_VERSION_CONTENT=$(curl --max-time 3 -fsSL "${SCRIPT_SOURCE_URL}" 2>/dev/null)

    if [ -z "$LATEST_VERSION_CONTENT" ]; then
        return
    fi
    
    local LATEST_VERSION
    LATEST_VERSION=$(echo "$LATEST_VERSION_CONTENT" | grep '^VERSION=' | sed -E 's/VERSION="([^"]+)"/\1/')

    if [ -z "$LATEST_VERSION" ] || [ "$VERSION" == "$LATEST_VERSION" ]; then
        return
    fi

    local CURRENT_MAJOR_VERSION=$(echo "$VERSION" | cut -d'v' -f2 | cut -d'.' -f1)
    local LATEST_MAJOR_VERSION=$(echo "$LATEST_VERSION" | cut -d'v' -f2 | cut -d'.' -f1)

    if [ "$LATEST_MAJOR_VERSION" -gt "$CURRENT_MAJOR_VERSION" ]; then
        case "$command_arg" in
            version|""|-h|--help)
                WARN "MANDATORY UPDATE RECOMMENDED. A new major version (${LATEST_VERSION}) is available. Please run 'kubectl ktool upgrade'."
                ;;
            *)
                error "Mandatory update required. A new major version (${LATEST_VERSION}) is available. Please run 'kubectl ktool upgrade'."
                ;;
        esac
    else
        WARN "A new version (${LATEST_VERSION}) is available. Please run 'kubectl ktool upgrade' to update."
    fi
}


# --- Upgrade Command Logic ---
handle_upgrade() {
    echo "Current version: ${VERSION}"
    
    local TMP_FILE="/tmp/kubectl-ktool.new.$$"

    echo "Fetching latest version from ${RELEASE_BRANCH} branch..."
    if ! curl -fsSL "${SCRIPT_SOURCE_URL}" -o "${TMP_FILE}"; then
        error "Could not download the latest script from the '${RELEASE_BRANCH}' branch."
        rm -f "${TMP_FILE}"
        exit 1
    fi

    LATEST_VERSION=$(grep '^VERSION=' "${TMP_FILE}" | sed -E 's/VERSION="([^"]+)"/\1/')

    if [ -z "$LATEST_VERSION" ]; then
        error "Could not determine the latest version from the script on the '${RELEASE_BRANCH}' branch."
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


# --- Collect Logs Logic ---
collect_logs() {
    NAMESPACE="panw"
    KUBECONFIG_FLAG=""
    CONTEXT_FLAG=""
    shift
    while [[ "$#" -gt 0 ]]; do
        case $1 in
            -n|--namespace)
                NAMESPACE="$2"
                shift 2
                ;;
            --kubeconfig)
                KUBECONFIG_FLAG="--kubeconfig $2"
                shift 2
                ;;
            --context)
                CONTEXT_FLAG="--context $2"
                shift 2
                ;;
            *)
                error "Unknown option for collect-logs: $1"
                ;;
        esac
    done

    echo "--> Verifying namespace '${NAMESPACE}' exists..."
    if ! kubectl ${KUBECONFIG_FLAG} ${CONTEXT_FLAG} get namespace "${NAMESPACE}" &> /dev/null; then
        error "Namespace '${NAMESPACE}' not found. Please verify the namespace name and your cluster context."
    fi

    HELM_RELEASE_1="konnector"
    HELM_RELEASE_2="k8s-connector-manager"
    BUNDLE_DIR="konnector-support-bundle-${NAMESPACE}-${VERSION}-$(date +"%Y%m%d-%H%M%S")"
    
    echo "Starting support bundle collection for namespace: ${NAMESPACE}"
    echo "Output will be saved to ${BUNDLE_DIR}.tar.gz"

    mkdir -p "${BUNDLE_DIR}"

    collect_cmd() {
        local title="$1"
        local cmd="$2"
        local file="$3"
        echo "  -> Collecting ${title}..."
        bash -c "$cmd" > "${BUNDLE_DIR}/${file}" 2>&1
    }

    echo "[1/6] Collecting Cluster Information..."
    mkdir -p "${BUNDLE_DIR}/cluster-info"
    collect_cmd "Kubernetes version" "kubectl ${KUBECONFIG_FLAG} ${CONTEXT_FLAG} version" "cluster-info/version.txt"
    collect_cmd "Node details" "kubectl ${KUBECONFIG_FLAG} ${CONTEXT_FLAG} get nodes -o wide" "cluster-info/nodes.txt"

    echo "[2/6] Collecting Namespace Information..."
    mkdir -p "${BUNDLE_DIR}/namespace-info"
    collect_cmd "Events in namespace" "kubectl ${KUBECONFIG_FLAG} ${CONTEXT_FLAG} get events -n ${NAMESPACE} --sort-by='.lastTimestamp'" "namespace-info/events.txt"

    # 3. Helm Info - now with a check
    echo "[3/6] Collecting Helm Release Information..."
    if command -v helm &> /dev/null; then
        mkdir -p "${BUNDLE_DIR}/helm"
        collect_cmd "Helm status for ${HELM_RELEASE_1}" "helm ${KUBECONFIG_FLAG} ${CONTEXT_FLAG} status ${HELM_RELEASE_1} -n ${NAMESPACE}" "helm/status-${HELM_RELEASE_1}.txt"
        collect_cmd "Helm values for ${HELM_RELEASE_1}" "helm ${KUBECONFIG_FLAG} ${CONTEXT_FLAG} get values ${HELM_RELEASE_1} -n ${NAMESPACE} -a" "helm/values-${HELM_RELEASE_1}.yaml"
        collect_cmd "Helm status for ${HELM_RELEASE_2}" "helm ${KUBECONFIG_FLAG} ${CONTEXT_FLAG} status ${HELM_RELEASE_2} -n ${NAMESPACE}" "helm/status-${HELM_RELEASE_2}.txt"
        collect_cmd "Helm values for ${HELM_RELEASE_2}" "helm ${KUBECONFIG_FLAG} ${CONTEXT_FLAG} get values ${HELM_RELEASE_2} -n ${NAMESPACE} -a" "helm/values-${HELM_RELEASE_2}.yaml"
    else
        WARN "helm command not found. Skipping Helm data collection."
    fi

    echo "[4/6] Collecting Workload Statuses..."
    mkdir -p "${BUNDLE_DIR}/workloads"
    collect_cmd "All workloads (wide)" "kubectl ${KUBECONFIG_FLAG} ${CONTEXT_FLAG} get all -n ${NAMESPACE} -o wide" "workloads/get-all-wide.txt"
    collect_cmd "All workloads (yaml)" "kubectl ${KUBECONFIG_FLAG} ${CONTEXT_FLAG} get all -n ${NAMESPACE} -o yaml" "workloads/get-all.yaml"
    
    echo "  -> Describing all workloads..."
    for kind in pod deployment statefulset daemonset service configmap replicaset ingress; do
        RESOURCES=$(kubectl ${KUBECONFIG_FLAG} ${CONTEXT_FLAG} get "$kind" -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
        if [ -n "$RESOURCES" ]; then
            mkdir -p "${BUNDLE_DIR}/workloads/${kind}"
            for name in $RESOURCES; do
                collect_cmd "${kind}/${name}" "kubectl ${KUBECONFIG_FLAG} ${CONTEXT_FLAG} describe ${kind} ${name} -n ${NAMESPACE}" "workloads/${kind}/${name}.describe.txt"
            done
        fi
    done

    echo "[5/6] Collecting Pod Logs..."
    mkdir -p "${BUNDLE_DIR}/logs"
    PODS=$(kubectl ${KUBECONFIG_FLAG} ${CONTEXT_FLAG} get pods -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
    for pod in $PODS; do
        CONTAINERS=$(kubectl ${KUBECONFIG_FLAG} ${CONTEXT_FLAG} get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.spec.containers[*].name} {.spec.initContainers[*].name}' 2>/dev/null)
        for container in $CONTAINERS; do
            collect_cmd "Logs for ${pod}/${container}" "kubectl ${KUBECONFIG_FLAG} ${CONTEXT_FLAG} logs ${pod} -c ${container} -n ${NAMESPACE}" "logs/${pod}_${container}.log"
            collect_cmd "Previous logs for ${pod}/${container}" "kubectl ${KUBECONFIG_FLAG} ${CONTEXT_FLAG} logs ${pod} -c ${container} -n ${NAMESPACE} --previous" "logs/${pod}_${container}.previous.log"
        done
    done

    echo "[6/6] Collecting Operator Configurations..."
    mkdir -p "${BUNDLE_DIR}/operator"
    collect_cmd "Validating Webhooks" "kubectl ${KUBECONFIG_FLAG} ${CONTEXT_FLAG} get validatingwebhookconfigurations -l 'app.kubernetes.io/instance in (${HELM_RELEASE_1}, ${HELM_RELEASE_2})' -o yaml" "operator/validating-webhooks.yaml"
    collect_cmd "Mutating Webhooks" "kubectl ${KUBECONFIG_FLAG} ${CONTEXT_FLAG} get mutatingwebhookconfigurations -l 'app.kubernetes.io/instance in (${HELM_RELEASE_1}, ${HELM_RELEASE_2})' -o yaml" "operator/mutating-webhooks.yaml"
    
    echo "Packaging support bundle..."
    tar -czf "${BUNDLE_DIR}.tar.gz" "${BUNDLE_DIR}"
    
    rm -rf "${BUNDLE_DIR}"

    echo "Support bundle created successfully: ${BUNDLE_DIR}.tar.gz"
}


# --- SCRIPT EXECUTION STARTS HERE ---

# Run the synchronous update check. This is critical for the blocking logic.
check_for_updates "$1"

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
