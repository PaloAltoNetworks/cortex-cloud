( \
  set -e; \
  echo "--> Downloading kubectl-ktool..."; \
  curl -fsSL -o /tmp/kubectl-ktool "https://raw.githubusercontent.com/PaloAltoNetworks/cortex-cloud/ktool/kubectl-ktool.sh"; \
  echo "--> Making it executable..."; \
  chmod +x /tmp/kubectl-ktool; \
  echo "--> Moving to /usr/local/bin (may require password)..."; \
  sudo mv /tmp/kubectl-ktool /usr/local/bin/kubectl-ktool; \
  echo -e "\n\033[32m✅ kubectl-ktool installed successfully!\033[0m"; \
  echo -e "\nRun 'kubectl ktool version' to verify."; \
)
