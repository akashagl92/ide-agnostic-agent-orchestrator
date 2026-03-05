#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
source "$script_dir/pai_core_lib.sh"

ROOT_DIR="$(pai_resolve_root)"
RUNTIME_ENV="$ROOT_DIR/.pai/config/runtime.env"
PROFILE_ENV="$ROOT_DIR/.pai/runtime/profile.env"

allowed_profile_keys=(PROFILE LOCKED REASON UPDATED_AT)

echo "ROOT_DIR=$ROOT_DIR"
echo "RUNTIME_ENV=$RUNTIME_ENV"
echo "PROFILE_ENV=$PROFILE_ENV"

if [[ ! -f "$RUNTIME_ENV" ]]; then
  echo "WARN missing runtime baseline file"
fi

if [[ ! -f "$PROFILE_ENV" ]]; then
  echo "INFO profile.env missing (will be created by runtime_guard)"
  exit 0
fi

bad=0
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ -n "$line" ]] || continue
  [[ "$line" == \#* ]] && continue
  [[ "$line" == *=* ]] || continue
  key="${line%%=*}"
  ok=0
  for k in "${allowed_profile_keys[@]}"; do
    if [[ "$key" == "$k" ]]; then
      ok=1
      break
    fi
  done
  if [[ "$ok" -ne 1 ]]; then
    echo "DRIFT profile.env contains non-transient key: $key"
    bad=1
  fi
done < "$PROFILE_ENV"

if [[ "$bad" -eq 1 ]]; then
  echo "STATUS=DRIFT_DETECTED"
  exit 3
fi

echo "STATUS=OK"
