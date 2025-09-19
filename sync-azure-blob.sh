#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./sync-azure-blob.sh "."                 # sync whole container to repo root
#   ./sync-azure-blob.sh "prefix/a" "b/c"    # sync specific prefixes (space-separated args)

PREFIXES=("$@")
if [ ${#PREFIXES[@]} -eq 0 ]; then
  PREFIXES=("." )
fi

: "${AZURE_STORAGE_ACCOUNT:?AZURE_STORAGE_ACCOUNT missing}"
: "${AZURE_CONTAINER:?AZURE_CONTAINER missing}"

# Require either KEY or SAS
if [[ -z "${AZURE_STORAGE_KEY:-}" && -z "${AZURE_STORAGE_SAS_TOKEN:-}" ]]; then
  echo "Set AZURE_STORAGE_KEY or AZURE_STORAGE_SAS_TOKEN"; exit 1
fi

# Work dirs (macOS-safe)
REPO_DIR="$(pwd)"
AZTMP="/tmp/aztmp"
mkdir -p "$AZTMP"

# Git author (optional)
git config user.name  "local-sync-bot"
git config user.email "local-sync-bot@example.com" || true

# Raise file handle limit (best-effort)
ulimit -n 65536 || true

# Route temp/logs to fast disk
export TMPDIR="${AZTMP}"
export TEMP="${AZTMP}"
export TMP="${AZTMP}"

# AzCopy tuning & auth
export AZCOPY_CONCURRENCY_VALUE=8
export AZCOPY_LOG_LOCATION="${AZTMP}/azcopy-logs"
export AZCOPY_JOB_PLAN_LOCATION="${AZTMP}/azcopy-plan"
mkdir -p "$AZCOPY_LOG_LOCATION" "$AZCOPY_JOB_PLAN_LOCATION"

if [[ -n "${AZURE_STORAGE_KEY:-}" ]]; then
  export AZCOPY_ACCOUNT_KEY="${AZURE_STORAGE_KEY}"
fi

HAD_ERRORS=0

for p in "${PREFIXES[@]}"; do
  if [[ "$p" == "." || "$p" == "/" || -z "$p" ]]; then
    SRC_URL="https://${AZURE_STORAGE_ACCOUNT}.blob.core.windows.net/${AZURE_CONTAINER}"
    TARGET_DIR="."
    LABEL="(root)"
  else
    # If you're using a SAS token, append it to the URL
    if [[ -n "${AZURE_STORAGE_SAS_TOKEN:-}" ]]; then
      SRC_URL="https://${AZURE_STORAGE_ACCOUNT}.blob.core.windows.net/${AZURE_CONTAINER}/${p}${AZURE_STORAGE_SAS_TOKEN}"
    else
      SRC_URL="https://${AZURE_STORAGE_ACCOUNT}.blob.core.windows.net/${AZURE_CONTAINER}/${p}"
    fi
    TARGET_DIR="./$p"
    LABEL="$p"
  fi

  echo "==> Downloading: ${LABEL} -> ${TARGET_DIR}"
  mkdir -p "$TARGET_DIR"

  set +e
  azcopy copy "$SRC_URL" "$TARGET_DIR" --recursive --overwrite=true --log-level INFO
  AC_STATUS=$?
  set -e

  LASTLOG="$(ls -t "${AZCOPY_LOG_LOCATION}"/*.log 2>/dev/null | head -n1 || true)"
  if [ "$AC_STATUS" -ne 0 ]; then
    HAD_ERRORS=1
    echo "⚠️  AzCopy returned $AC_STATUS for ${LABEL}. See log: $LASTLOG"
    if [ -n "$LASTLOG" ]; then
      echo "---- AzCopy error tail (${LABEL}) ----"
      tail -n 200 "$LASTLOG" | sed 's/^/LOG: /'
      echo "--------------------------------------"
    fi
  fi

  echo "==> Git add/commit/push: $LABEL"
  git add --all "$TARGET_DIR" || true
  if ! git diff --cached --quiet -- "$TARGET_DIR"; then
    git commit -m "Local sync from Azure ${LABEL} - $(date -u +'%Y-%m-%d %H:%M:%S UTC')"
    # Remove the next line if you don't want automatic push:
    git push
    git gc --prune=now || true
  else
    echo "No changes for ${LABEL}."
  fi
done

echo "AzCopy logs at: $AZCOPY_LOG_LOCATION"

# Uncomment to fail script if any prefix had errors
# if [ "$HAD_ERRORS" -ne 0 ]; then
#   echo "Finished with AzCopy errors (see logs)."
#   exit 1
# fi
