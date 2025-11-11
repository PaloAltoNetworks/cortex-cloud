#!/bin/bash

readonly ENV_NAME="name"
readonly ENV_VALUE="twistlock_scanner"

echo "🔍 Checking for containers where ENV ${ENV_NAME}=${ENV_VALUE}..."
MATCHED_CONTAINER_IDS=()

ALL_CONTAINER_IDS=$(docker ps -a -q)

for ID in ${ALL_CONTAINER_IDS}; do
    ENV_CHECK=$(docker inspect -f "{{range .Config.Env}}{{$parts := splitn . \"=\" 2}}{{if and (eq (len $parts) 2) (eq (index $parts 0) \"${ENV_NAME}\")}}{{(index $parts 1)}}{{end}}{{end}}" "$ID" 2>/dev/null)

    if [[ "$ENV_CHECK" == "$ENV_VALUE" ]]; then
        MATCHED_CONTAINER_IDS+=("$ID")
    fi
done

if [ ${#MATCHED_CONTAINER_IDS[@]} -eq 0 ]; then
    echo "✅ No containers found with ENV ${ENV_NAME}=${ENV_VALUE}."
    exit 0
fi

echo "🧱 Containers with ENV ${ENV_NAME}=${ENV_VALUE}:"
for ID in "${MATCHED_CONTAINER_IDS[@]}"; do
  NAME=$(docker inspect -f '{{.Name}}' "$ID" | sed 's/^\///')
  echo " - **$ID** (${NAME})"
done

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
