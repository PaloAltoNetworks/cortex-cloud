#!/bin/bash
#
# kubectl-ktool: A kubectl plugin with various tools for Konnector.

# --- CONFIGURATION (SINGLE SOURCE OF TRUTH) ---
# The version of THIS script. This is the only place you need to update the version.
VERSION="v0.1.0"
# GitHub repository details for self-upgrading
GITHUB_USER="PaloAltoNetworks"
GITHUB_REPO="cortex-cloud"


# --- Usage Function ---
usage() {
    echo "Usage: kubectl ktool <command> [options]"
    echo
    echo "A tool for managing the Konnector agent."
    echo
    echo "Commands:"
    echo "  collect-logs    Collects a diagnostic support bundle."
    echo "  upgrade         Upgrades kubectl-ktool to the latest version."
    echo "  version         Prints the current version of the tool."
    echo
    echo "Options for 'collect-logs':"
    echo "  -n, --namespace   The namespace where the agent is installed. (Default: pan)"
}

# --- Upgrade Command Logic ---
handle_upgrade() {
    info "Checking for new versions of kubectl-ktool..."
    info "Current version: ${VERSION}"

    # --- NEW: Fetch the script from the main branch and read the VERSION variable from it ---
    local script_url_main="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/ktool/tools/kubectl-ktool.sh"
    # Download the script content, find the line starting with VERSION=, and extract the value in quotes.
    LATEST_VERSION=$(curl -s "${script_url_main}" | grep '^VERSION=' | sed -E 's/VERSION="([^"]+)"/\1/')

    if [ -z "$LATEST_VERSION" ]; then
        error "Could not determine the latest version from the script on the main branch."
        exit 1
    fi

    info "Latest version available: ${LATEST_VERSION}"

    if [ "$VERSION" == "$LATEST_VERSION" ]; then
        success "You are already using the latest version. No upgrade needed."
        exit 0
    fi

    info "A new version is available. Upgrading from ${VERSION} to ${LATEST_VERSION}..."

    INSTALL_PATH=$(which kubectl-ktool)
    if [ -z "$INSTALL_PATH" ]; then
        error "Could not determine the installation path of 'kubectl-ktool'. Cannot upgrade automatically."
        exit 1
    fi

    # Download URL still points to the file at a specific Git tag for immutability
    DOWNLOAD_URL="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${LATEST_VERSION}/bin/kubectl-ktool.sh"
    TMP_FILE="/tmp/kubectl-ktool.new"

    info "Downloading new version from ${DOWNLOAD_URL}..."
    if ! curl -fsSL "${DOWNLOAD_URL}" -o "${TMP_FILE}"; then
        error "Download failed. Please try again later."
        exit 1
    fi

    chmod +x "${TMP_FILE}"

    info "Replacing old script at ${INSTALL_PATH}..."
    if [[ -w "$(dirname "$INSTALL_PATH")" ]]; then
        mv "${TMP_FILE}" "${INSTALL_PATH}"
    elif command -v sudo &> /dev/null; then
        sudo mv "${TMP_FILE}" "${INSTALL_PATH}"
    else
        error "Cannot write to ${INSTALL_PATH}. Please run 'kubectl ktool upgrade' with sudo."
        exit 1
    fi

    success "Upgrade complete! You are now on version ${LATEST_VERSION}."
}


# --- Version Command Logic ---
handle_version() {
    echo "kubectl-ktool version ${VERSION}"
}


# --- Collect Logs Logic (Placeholder) ---
# NOTE: This is a placeholder. You need to insert your full log collection logic here.
collect_logs() {
    # --- Argument Parsing for collect-logs ---
    NAMESPACE="pan" # Set default namespace
    shift # remove 'collect-logs'
    while [[ "$#" -gt 0 ]]; do
        case $1 in
            -n|--namespace) NAMESPACE="$2"; shift; shift;;
            *) echo "Unknown option for collect-logs: $1"; usage; exit 1;;
        esac
    done

    # --- Configuration ---
    HELM_RELEASE_1="konnector"
    HELM_RELEASE_2="k8s-connector-manager"
    BUNDLE_DIR="konnector-support-bundle-${NAMESPACE}-$(date +%Y%m%d-%H%M%S)"

    info "Starting support bundle collection for namespace: $NAMESPACE"
    # PASTE YOUR FULL LOG COLLECTION LOGIC HERE
    echo "[STUB] Collecting logs for namespace ${NAMESPACE}..."
    success "Bundle created: ${BUNDLE_DIR}.tar.gz"
}

# Helper functions for colors and info messages
info() { echo -e "\033[34m[INFO]\033[0m $1"; }
success() { echo -e "\033[32m[SUCCESS]\033[0m $1"; }
error() { echo -e "\033[31m[ERROR]\033[0m $1"; }


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
        echo "Error: Unknown command '$1'"
        usage
        exit 1
        ;;
esac
