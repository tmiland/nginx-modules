#!/usr/bin/env bash
# Build a source bundle for nginx_installer.sh.
set -euo pipefail
umask 022

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
# shellcheck source=lib.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

MODULES_DIR=$ROOT_DIR/modules
BUNDLES_DIR=$ROOT_DIR/bundles
DEFAULT_OUT=$ROOT_DIR/dist
TMP_BASE=$ROOT_DIR/.tmp

BUNDLE=full
ONLY_IDS=
OUT_DIR=

usage() {
  cat <<EOF
Usage: bash scripts/build_bundle.sh [options]

Options:
  --bundle NAME   Bundle to build (default: full)
  --only IDS      Comma-separated module ids; useful for CI smoke tests
  --out DIR       Output directory (default: dist, or \$MODULES_OUT)
  -h, --help      Show this help

The archive is written to <out>/nginx-modules-<bundle>.tar.gz. When --only
is used, the archive name still follows --bundle (full by default).
EOF
}

while (($#)); do
  case $1 in
    --bundle)
      (($# >= 2)) || die "--bundle requires a value"
      BUNDLE=$2
      shift 2
      ;;
    --bundle=*)
      BUNDLE=${1#*=}
      shift
      ;;
    --only)
      (($# >= 2)) || die "--only requires a value"
      ONLY_IDS=$2
      shift 2
      ;;
    --only=*)
      ONLY_IDS=${1#*=}
      shift
      ;;
    --out)
      (($# >= 2)) || die "--out requires a value"
      OUT_DIR=$2
      shift 2
      ;;
    --out=*)
      OUT_DIR=${1#*=}
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

[[ $BUNDLE =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "invalid bundle name: $BUNDLE"
[[ -d $MODULES_DIR ]] || die "modules directory not found: $MODULES_DIR"

if [[ -z $OUT_DIR ]]; then
  OUT_DIR=${MODULES_OUT:-$DEFAULT_OUT}
fi
[[ -n $OUT_DIR ]] || die "output directory must not be empty"
mkdir -p "$OUT_DIR"
OUT_DIR=$(cd -- "$OUT_DIR" && pwd)

mkdir -p "$TMP_BASE"
WORK=$(mktemp -d "$TMP_BASE/build.XXXXXX")
cleanup() {
  rm -rf -- "$WORK"
}
trap cleanup EXIT

declare -A MODULE_FILE=()
declare -a MODULE_IDS=()
while IFS= read -r file; do
  id=$(conf_get "$file" id || true)
  [[ -n $id ]] || die "missing id in $file"
  [[ -z ${MODULE_FILE[$id]:-} ]] || die "duplicate module id '$id'"
  MODULE_FILE[$id]=$file
  MODULE_IDS+=("$id")
done < <(find "$MODULES_DIR" -maxdepth 1 -type f -name '*.mod' -print | LC_ALL=C sort)
((${#MODULE_IDS[@]})) || die "no .mod files found in $MODULES_DIR"

mod_get() {
  local id=$1 key=$2
  conf_get "${MODULE_FILE[$id]:-}" "$key"
}

mod_require() {
  local id=$1 key=$2 value
  value=$(mod_get "$id" "$key") || die "module '$id' is missing key '$key'"
  printf '%s\n' "$value"
}

declare -A SELECTED=()
declare -A VISITING=()
declare -a ORDER=()
declare -a ROOTS=()

add_module() {
  local id=$1 parent=${2:-}
  local reqs dep

  [[ -n ${MODULE_FILE[$id]:-} ]] || {
    if [[ -n $parent ]]; then
      die "unknown module '$id' (required by '$parent')"
    fi
    die "unknown module '$id'"
  }
  if [[ -n ${SELECTED[$id]:-} ]]; then
    return 0
  fi
  [[ -z ${VISITING[$id]:-} ]] || die "dependency cycle at '$id'"
  VISITING[$id]=1

  reqs=$(mod_get "$id" requires || true)
  while IFS= read -r dep; do
    [[ -n $dep ]] || continue
    add_module "$dep" "$id"
  done < <(list_split "$reqs")

  unset 'VISITING[$id]'
  SELECTED[$id]=1
  ORDER+=("$id")
}

if [[ -n $ONLY_IDS ]]; then
  while IFS= read -r id; do
    [[ -n $id ]] || continue
    [[ -n ${MODULE_FILE[$id]:-} ]] || die "unknown module in --only: $id"
    ROOTS+=("$id")
  done < <(list_split "$ONLY_IDS")
  ((${#ROOTS[@]})) || die "--only selected no modules"
elif [[ $BUNDLE == full ]]; then
  for id in "${MODULE_IDS[@]}"; do
    status=$(mod_get "$id" status || true)
    if [[ $status == active ]]; then
      ROOTS+=("$id")
    fi
  done
else
  bundle_file=$BUNDLES_DIR/$BUNDLE.bundle
  [[ -f $bundle_file ]] || die "bundle not found: $bundle_file"
  bundle_modules=$(conf_get "$bundle_file" modules || true)
  [[ -n $bundle_modules ]] || die "bundle '$BUNDLE' has no modules"
  while IFS= read -r id; do
    [[ -n $id ]] || continue
    ROOTS+=("$id")
  done < <(list_split "$bundle_modules")
fi

for id in "${ROOTS[@]}"; do
  add_module "$id"
done

final_dir() {
  local id=$1 dir version versioned
  dir=$(mod_require "$id" dir)
  version=$(mod_require "$id" version)
  versioned=$(mod_require "$id" versioned_dir)

  [[ $dir != /* && $dir != *..* ]] || die "unsafe dir for '$id': $dir"
  [[ $version != */* && $version != *..* ]] || die "unsafe version for '$id': $version"

  if [[ $versioned == yes ]]; then
    printf '%s-%s\n' "$dir" "$version"
  else
    printf '%s\n' "$dir"
  fi
}

fetch() {
  local url=$1 out=$2
  curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 1200 \
    -o "$out" "$url" || die "download failed: $url"
}

verify_sha256() {
  local file=$1 expected=$2 actual
  [[ -n $expected ]] || return 0
  actual=$(sha256sum "$file" | awk '{print $1}')
  [[ $actual == "$expected" ]] || die \
    "sha256 mismatch for $file (expected $expected, got $actual)"
}

remove_git_metadata() {
  local dest=$1
  find "$dest" -type d -name .git -prune -exec rm -rf -- {} +
  find "$dest" -type f -name .git -delete
}

install_git() {
  local id=$1 dest=$2 url ref submodules actual
  url=$(mod_require "$id" url)
  ref=$(mod_require "$id" ref)
  submodules=$(mod_require "$id" submodules)

  mkdir -p "$dest" || die "cannot create '$dest' for '$id'"
  git -C "$dest" init --quiet || die "git init failed for '$id'"
  git -C "$dest" remote add origin "$url" || die "git remote failed for '$id'"
  if git -C "$dest" fetch --quiet --depth 1 origin "$ref"; then
    git -C "$dest" checkout --quiet FETCH_HEAD || die "cannot checkout pin for '$id'"
  else
    git -C "$dest" fetch --quiet origin || die "cannot fetch '$id'"
    git -C "$dest" checkout --quiet "$ref" || die "cannot checkout pin for '$id'"
  fi
  actual=$(git -C "$dest" rev-parse HEAD)
  [[ $actual == "$ref" ]] || die "pin mismatch for '$id' (wanted $ref, got $actual)"

  if [[ $submodules == yes ]]; then
    if ! git -C "$dest" submodule update --init --recursive --depth 1; then
      printf 'warning: shallow submodule fetch failed for %s; retrying without --depth\n' \
        "$id" >&2
      git -C "$dest" submodule update --init --recursive \
        || die "submodule update failed for '$id'"
    fi
  fi
  remove_git_metadata "$dest"
}

install_archive() {
  local id=$1 dest=$2 url sha strip tmp
  url=$(mod_require "$id" url)
  sha=$(mod_get "$id" sha256 || true)
  strip=$(mod_require "$id" strip)
  [[ $strip =~ ^[0-9]+$ ]] || die "invalid strip for '$id': $strip"

  tmp=$WORK/download-$id.tar
  fetch "$url" "$tmp"
  verify_sha256 "$tmp" "$sha"

  mkdir -p "$dest"
  if ((strip > 0)); then
    tar -xf "$tmp" -C "$dest" --strip-components="$strip" --no-same-owner \
      || die "extract failed for '$id'"
  else
    tar -xf "$tmp" -C "$dest" --no-same-owner || die "extract failed for '$id'"
  fi
  [[ -n $(find "$dest" -mindepth 1 -maxdepth 1 -print -quit) ]] \
    || die "archive for '$id' extracted no files"
}

install_zip() {
  local id=$1 dest=$2 url sha tmp extract entry candidate
  url=$(mod_require "$id" url)
  sha=$(mod_get "$id" sha256 || true)

  tmp=$WORK/download-$id.zip
  extract=$WORK/unzip-$id
  fetch "$url" "$tmp"
  verify_sha256 "$tmp" "$sha"
  mkdir -p "$extract"
  unzip -q "$tmp" -d "$extract" || die "unzip failed for '$id'"

  candidate=
  shopt -s nullglob dotglob
  for entry in "$extract"/*; do
    if [[ -d $entry ]]; then
      candidate=$entry
      break
    fi
  done
  shopt -u nullglob dotglob
  [[ -n $candidate ]] || die "zip for '$id' has no top-level directory"

  mkdir -p "$(dirname -- "$dest")"
  [[ ! -e $dest ]] || die "destination already exists: $dest"
  mv -- "$candidate" "$dest"
}

install_file() {
  local id=$1 dest=$2 url sha
  url=$(mod_require "$id" url)
  sha=$(mod_get "$id" sha256 || true)

  mkdir -p "$(dirname -- "$dest")"
  [[ ! -e $dest ]] || die "destination already exists: $dest"
  fetch "$url" "$dest"
  verify_sha256 "$dest" "$sha"
}

ROOT_NAME=nginx-modules-$BUNDLE
STAGING=$WORK/staging
DEST_ROOT=$STAGING/$ROOT_NAME
mkdir -p "$DEST_ROOT/modules"

printf 'Building %s bundle (%d module roots)...\n' "$BUNDLE" "${#ROOTS[@]}"
for id in "${ORDER[@]}"; do
  kind=$(mod_require "$id" kind)
  dest_rel=$(final_dir "$id")
  dest=$DEST_ROOT/modules/$dest_rel

  case $kind in
    git) install_git "$id" "$dest" ;;
    archive) install_archive "$id" "$dest" ;;
    zip) install_zip "$id" "$dest" ;;
    file) install_file "$id" "$dest" ;;
    *) die "unsupported kind '$kind' for '$id'" ;;
  esac

  [[ -e $dest ]] || die "module '$id' did not produce '$dest_rel'"
  printf '  %-22s %s\n' "$id" "$dest_rel"
done

declare -A VERSIONS=()
for id in "${ORDER[@]}"; do
  var=$(mod_get "$id" version_var || true)
  [[ -n $var ]] || continue
  value=$(mod_require "$id" version)
  [[ $var =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "invalid version_var for '$id'"
  [[ $value =~ ^[A-Za-z0-9._+~-]+$ ]] || die "unsafe version value for '$id': $value"
  if [[ -n ${VERSIONS[$var]:-} && ${VERSIONS[$var]} != "$value" ]]; then
    die "conflicting values for $var"
  fi
  VERSIONS[$var]=$value
done

{
  if ((${#VERSIONS[@]})); then
    while IFS= read -r var; do
      printf '%s=%s\n' "$var" "${VERSIONS[$var]}"
    done < <(printf '%s\n' "${!VERSIONS[@]}" | LC_ALL=C sort)
  fi
} > "$DEST_ROOT/versions.conf"

{
  printf '# id|dir|kind|build|requires|env\n'
  for id in "${ORDER[@]}"; do
    dir=$(final_dir "$id")
    kind=$(mod_require "$id" kind)
    build=$(mod_get "$id" build || true)
    requires=$(mod_get "$id" requires || true)
    env=$(mod_get "$id" env || true)
    for field in "$id" "$dir" "$kind" "$build" "$requires" "$env"; do
      [[ $field != *'|'* ]] || die "field contains '|' for '$id'"
    done
    printf '%s|%s|%s|%s|%s|%s\n' \
      "$id" "$dir" "$kind" "$build" "$requires" "$env"
  done
} > "$DEST_ROOT/modules.conf"

{
  printf '# bundle|comma-separated module ids\n'
  for bundle_file in "$ROOT_DIR"/bundles/*.bundle; do
    bundle_id=$(conf_get "$bundle_file" id || true)
    bundle_modules=$(conf_get "$bundle_file" modules || true)
    [[ -n $bundle_id && -n $bundle_modules ]] || continue
    [[ $bundle_id == legacy ]] && continue
    printf '%s|%s\n' "$bundle_id" "$bundle_modules"
  done
} > "$DEST_ROOT/bundles.conf"

all_ids=
for id in "${ORDER[@]}"; do
  # The third-party HTTP/3 stack targets nginx <= 1.24. nginx 1.25+ has
  # native HTTP/3 (--with-http_v3_module), so keep it out of "all".
  case $id in
    openssl|libressl|hpack|pagespeed|quiche|http3|hpack-http3) continue ;;
  esac
  all_ids=${all_ids:+$all_ids,}$id
done
printf 'all|%s\n' "$all_ids" >> "$DEST_ROOT/bundles.conf"

ARCHIVE=$OUT_DIR/nginx-modules-$BUNDLE.tar.gz
TMP_ARCHIVE=$WORK/nginx-modules-$BUNDLE.tar.gz
tar --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner \
  --no-same-owner -C "$STAGING" -cf - "$ROOT_NAME" | gzip -n > "$TMP_ARCHIVE"
mv -f -- "$TMP_ARCHIVE" "$ARCHIVE"

(cd "$OUT_DIR" && {
  if [[ -f SHA256SUMS ]]; then
    awk -v name="nginx-modules-$BUNDLE.tar.gz" '$2 != name { print }' \
      SHA256SUMS > "$WORK/SHA256SUMS.filtered"
    cat "$WORK/SHA256SUMS.filtered" > SHA256SUMS
  fi
  sha256sum "nginx-modules-$BUNDLE.tar.gz" >> SHA256SUMS
})
SUM=$(sha256sum "$ARCHIVE" | awk '{print $1}')

printf 'Built %s\n' "$ARCHIVE"
printf '  modules: %d (%d requested)\n' "${#ORDER[@]}" "${#ROOTS[@]}"
printf '  sha256:  %s\n' "$SUM"
