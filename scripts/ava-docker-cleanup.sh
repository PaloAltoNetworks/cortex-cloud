#!/bin/bash

readonly ENV_STRING_TO_FIND="name=twistlock_scanner"

echo "🔍 Checking for containers with ENV: ${ENV_STRING_TO_FIND}..."
MATCHED_CONTAINER_IDS=()

ALL_CONTAINER_IDS=$(docker ps -a -q)

if [ -z "$ALL_CONTAINER_IDS" ]; then
    echo "ℹ️ No containers found on the system."
    exit 0
fi

for ID in ${ALL_CONTAINER_IDS}; do
    ENV_CHECK=$(docker inspect -f '{{range .Config.Env}}{{if eq . "'"${ENV_STRING_TO_FIND}"'"}}true{{end}}{{end}}' "$ID" 2>/dev/null)

    if [[ "$ENV_CHECK" == "true" ]]; then
        MATCHED_CONTAINER_IDS+=("$ID")
    fi
done

if [ ${#MATCHED_CONTAINER_IDS[@]} -eq 0 ]; then
    echo "✅ No containers found with ENV: ${ENV_STRING_TO_FIND}."
    exit 0
fi

echo "🧱 Containers with ENV: ${ENV_STRING_TO_FIND}:"
for ID in "${MATCHED_CONTAINER_IDS[@]}"; do
  NAME=$(docker inspect -f '{{.Name}}' "$ID" | sed 's/^\///')
  echo " - **$ID** (${NAME})"
done

echo "" # Add a newline for readability

read -r -p "⚠️ Do you want to delete these containers? (y/N): " confirm
if [[ "$confirm" =~ ^[yY]$ ]]; then
  echo "🗑️ Deleting containers..."
  if docker rm -f "${MATCHED_CONTAINER_IDS[@]}"; then
    echo "✅ Successfully removed the following containers:"
    for id in "${MATCHED_CONTAINER_IDS[@]}"; do
      echo " - $id"
    done
    echo "✅ Cleanup complete."
  else
    echo "❌ An error occurred during container deletion." >&2
    exit 1
  fi
else
  echo "❎ Deletion canceled."
fi
