#!/usr/bin/env bash
# Shared helpers for nginx-modules build scripts.
# The .mod/.bundle formats are a deliberately small TOML subset:
#   key = 'literal value'
#   key = "escaped value"
#   key = bare_value
# Comments start with #.

# conf_get <file> <key>
# Print the value of <key> from <file>. Returns 1 when the file or key is
# missing. The first matching key wins.
conf_get() {
  local file=${1:-} key=${2:-} raw line value rest ch out
  local i

  [[ -n $file && -n $key ]] || return 1
  [[ -r $file ]] || return 1

  while IFS= read -r raw || [[ -n $raw ]]; do
    line=${raw#"${raw%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [[ -z $line || $line == '#'* ]] && continue

    if [[ ! $line =~ ^([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
      continue
    fi
    [[ ${BASH_REMATCH[1]} == "$key" ]] || continue
    value=${BASH_REMATCH[2]}

    # Literal single-quoted string: no escape processing.
    if [[ $value =~ ^\'([^\']*)\'[[:space:]]*(#.*)?$ ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
      return 0
    fi

    # Basic double-quoted string with the usual short escapes.
    if [[ $value == '"'* ]]; then
      value=${value#'"'}
      out=''
      i=0
      while (( i < ${#value} )); do
        ch=${value:i:1}
        if [[ $ch == '"' ]]; then
          printf '%s\n' "$out"
          return 0
        fi
        if [[ $ch == "\\" ]]; then
          i=$((i + 1))
          ch=${value:i:1}
          case $ch in
            n) out+=$'\n' ;;
            r) out+=$'\r' ;;
            t) out+=$'\t' ;;
            '"' | "\\") out+=$ch ;;
            *) out+="\\$ch" ;;
          esac
        else
          out+=$ch
        fi
        i=$((i + 1))
      done
      return 1
    fi

    # Bare scalar, optionally followed by a comment.
    if [[ $value =~ ^([^[:space:]\#]+)[[:space:]]*(#.*)?$ ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
      return 0
    fi
    return 1
  done < "$file"

  return 1
}

# list_split <comma-separated-list>
# Print one trimmed item per line. Empty items are ignored.
list_split() {
  local item
  local -a items=()

  IFS=',' read -r -a items <<< "${1:-}"
  for item in "${items[@]}"; do
    item=${item#"${item%%[![:space:]]*}"}
    item=${item%"${item##*[![:space:]]}"}
    [[ -n $item ]] && printf '%s\n' "$item"
  done
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}
