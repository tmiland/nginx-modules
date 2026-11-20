#!/usr/bin/env bash
# Read-only drift checker for module pins.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
# shellcheck source=lib.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

MODULES_DIR=$ROOT_DIR/modules
MODE=check

usage() {
  cat <<EOF
Usage: bash scripts/update-modules.sh [--check]

--check   Compare pinned revisions and archive versions with upstream (default)
--write   Not implemented; edit modules/<id>.mod manually
EOF
}

while (($#)); do
  case $1 in
    --check)
      MODE='check'
      shift
      ;;
    --write)
      MODE='write'
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

if [[ $MODE == write ]]; then
  printf '%s\n' \
    "update-modules: --write is not implemented; edit the .mod pin and checksum manually" >&2
  exit 2
fi

mkdir -p "$ROOT_DIR/.tmp"
WORK=$(mktemp -d "$ROOT_DIR/.tmp/update.XXXXXX")
cleanup() {
  rm -rf -- "$WORK"
}
trap cleanup EXIT

API_HTTP=

api_get() {
  local url=$1
  if [[ -n ${GITHUB_TOKEN:-} ]]; then
    API_HTTP=$(curl -sS --max-time 30 -o "$WORK/api.json" -w '%{http_code}' \
      -H 'Accept: application/vnd.github+json' \
      -H "Authorization: Bearer $GITHUB_TOKEN" "$url") || API_HTTP=000
  else
    API_HTTP=$(curl -sS --max-time 30 -o "$WORK/api.json" -w '%{http_code}' \
      -H 'Accept: application/vnd.github+json' "$url") || API_HTTP=000
  fi
  [[ $API_HTTP == 200 ]]
}

normalize_version() {
  local value=$1
  value=${value#v}
  value=${value#V}
  printf '%s\n' "$value"
}

DRIFT=0
WARN=0
SKIPPED=0
OK=0

check_git() {
  local id=$1 url=$2 ref=$3 version=$4 tags direct peeled tag_sha

  if ! tags=$(timeout 90s git ls-remote --tags --heads "$url" 2>/dev/null); then
    printf 'WARN   %-22s git ls-remote failed\n' "$id"
    WARN=$((WARN + 1))
    return
  fi

  if ! awk -v pin="$ref" '$1 == pin { found = 1 } END { exit(found ? 0 : 1) }' \
    <<< "$tags"; then
    printf 'DRIFT  %-22s pinned ref %s not found upstream\n' "$id" "$ref"
    DRIFT=$((DRIFT + 1))
    return
  fi

  # If version is an exact tag name, the tag must still point at the pin.
  for tag in "$version" "v$version"; do
    direct=$(awk -v name="refs/tags/$tag" '$2 == name { print $1; exit }' <<< "$tags")
    peeled=$(awk -v name="refs/tags/$tag^{}" '$2 == name { print $1; exit }' <<< "$tags")
    tag_sha=${peeled:-$direct}
    if [[ -n $tag_sha ]]; then
      if [[ $tag_sha != "$ref" ]]; then
        printf 'DRIFT  %-22s tag %s points at %s, not pinned %s\n' \
          "$id" "$tag" "$tag_sha" "$ref"
        DRIFT=$((DRIFT + 1))
        return
      fi
      break
    fi
  done

  printf 'OK     %-22s pin %s present\n' "$id" "${ref:0:12}"
  OK=$((OK + 1))
}

check_archive() {
  local id=$1 repo=$2 url=$3 version=$4 status=$5 api latest

  if [[ $status != active ]]; then
    printf 'SKIP   %-22s status is %s\n' "$id" "$status"
    SKIPPED=$((SKIPPED + 1))
    return
  fi
  if [[ -z $repo || $url != https://github.com/* ]]; then
    printf 'SKIP   %-22s non-GitHub archive\n' "$id"
    SKIPPED=$((SKIPPED + 1))
    return
  fi

  api=https://api.github.com/repos/$repo/releases/latest
  if ! api_get "$api"; then
    if [[ $API_HTTP == 404 ]]; then
      printf 'SKIP   %-22s no GitHub release\n' "$id"
      SKIPPED=$((SKIPPED + 1))
    else
      printf 'WARN   %-22s GitHub API HTTP %s\n' "$id" "${API_HTTP:-unknown}"
      WARN=$((WARN + 1))
    fi
    return
  fi

  latest=$(python3 -c \
    'import json,sys; print(json.load(sys.stdin).get("tag_name") or "")' \
    < "$WORK/api.json" 2>/dev/null) || latest=
  if [[ -z $latest ]]; then
    printf 'SKIP   %-22s release has no tag\n' "$id"
    SKIPPED=$((SKIPPED + 1))
    return
  fi

  local latest_norm version_norm
  latest_norm=$(normalize_version "$latest")
  version_norm=$(normalize_version "$version")
  if [[ $latest_norm == "$version_norm" ]]; then
    printf 'OK     %-22s latest release %s\n' "$id" "$latest"
    OK=$((OK + 1))
    return
  fi
  if [[ $(printf '%s\n%s\n' "$latest_norm" "$version_norm" | sort -V | tail -n 1) == "$version_norm" ]]; then
    printf 'OK     %-22s pinned %s is newer than latest release %s\n' "$id" "$version" "$latest"
    OK=$((OK + 1))
    return
  fi

  printf 'DRIFT  %-22s pinned %s, latest release %s\n' "$id" "$version" "$latest"
  DRIFT=$((DRIFT + 1))
}

while IFS= read -r file; do
  id=$(conf_get "$file" id || true)
  kind=$(conf_get "$file" kind || true)
  status=$(conf_get "$file" status || true)
  repo=$(conf_get "$file" repo || true)
  url=$(conf_get "$file" url || true)
  version=$(conf_get "$file" version || true)
  ref=$(conf_get "$file" ref || true)

  [[ -n $id ]] || die "missing id in $file"

  case $kind in
    git)
      [[ -n $url && -n $ref ]] || die "module '$id' has incomplete git metadata"
      check_git "$id" "$url" "$ref" "$version"
      ;;
    archive | zip)
      [[ -n $url && -n $version ]] || die "module '$id' has incomplete archive metadata"
      check_archive "$id" "$repo" "$url" "$version" "$status"
      ;;
    file)
      printf 'SKIP   %-22s file patch (sha256 pinned)\n' "$id"
      SKIPPED=$((SKIPPED + 1))
      ;;
    *)
      die "module '$id' has unknown kind '$kind'"
      ;;
  esac
done < <(find "$MODULES_DIR" -maxdepth 1 -type f -name '*.mod' -print | LC_ALL=C sort)

printf 'summary: %d ok, %d drift, %d warnings, %d skipped\n' \
  "$OK" "$DRIFT" "$WARN" "$SKIPPED"

if ((DRIFT > 0)); then
  exit 1
fi
