#!/bin/bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_dir}/deploy-llamastack-openai-dev.sh"

grep -Fq 'Do you want to install or upgrade RHOAI on stable-3.x to 3.5.0? [y/N]' "$script"
grep -Fq 'rhods-operator.3.5.0' "$script"

if grep -Eq 'beta channel|3\.5\.0-ea\.' "$script"; then
  echo "Found stale RHOAI prerelease configuration in $script" >&2
  exit 1
fi
