#!/usr/bin/env bash
# Point the container's public symlink at a published Flutter release.
# publish records the previous target. rollback flips back. prune drops old shas.
set -euo pipefail

if [[ -z "${SITEHOST_LIB_LOADED:-}" ]]; then
  # shellcheck disable=SC1091
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
fi

: "${SITEHOST_APP_PATH:?SITEHOST_APP_PATH is required}"

action="${PUBLISH_ACTION:-publish}"
releases="${SITEHOST_APP_PATH}/releases"
live="${SITEHOST_APP_PATH}/public"
state="${releases}/.state"

assert_absolute_path "SITEHOST_APP_PATH" "$SITEHOST_APP_PATH"

case "$action" in
  publish|rollback|prune) ;;
  *)
    echo "PUBLISH_ACTION must be publish, rollback, or prune" >&2
    exit 1
    ;;
esac

# Read one key from the state file. Missing keys are empty.
state_get() {
  local key="$1"
  local line
  [[ -f "$state" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      "${key}="*)
        printf '%s' "${line#"${key}"=}"
        return 0
        ;;
    esac
  done < "$state"
}

# Write previous and current. Values are releases/<name> or empty.
state_put() {
  local previous="$1"
  local current="$2"
  local tmp
  tmp="$(mktemp)"
  printf 'previous=%s\ncurrent=%s\n' "$previous" "$current" > "$tmp"
  mv "$tmp" "$state"
}

# releases/<name> with a single safe path segment.
assert_release_rel() {
  local label="$1"
  local value="$2"
  case "$value" in
    releases/[A-Za-z0-9._-]*) ;;
    *)
      echo "${label} must be a releases/<name> path" >&2
      exit 1
      ;;
  esac
  case "$value" in
    *..*|releases/*/*|releases/)
      echo "${label} must be a single path segment under releases" >&2
      exit 1
      ;;
  esac
}

# Replace public with a symlink. GNU mv -T is one rename. BSD mv has no -T.
flip_public() {
  local rel="$1"
  local next="${SITEHOST_APP_PATH}/public.next"
  ln -sfn "$rel" "$next"
  if mv -T "$next" "$live" 2>/dev/null; then
    return 0
  fi
  rm -f "$next"
  ln -sfn "$rel" "$live"
}

require_index() {
  local rel="$1"
  if [[ ! -f "${SITEHOST_APP_PATH}/${rel}/index.html" ]]; then
    echo "Release is missing index.html: ${SITEHOST_APP_PATH}/${rel}" >&2
    exit 1
  fi
}

publish_release() {
  local sha previous="" rel current_link
  sha="${DEPLOY_SHA:?DEPLOY_SHA is required}"
  if [[ ! "$sha" =~ ^[0-9a-fA-F]{40}$ ]]; then
    echo "DEPLOY_SHA must be a 40 character git commit" >&2
    exit 1
  fi
  rel="releases/${sha}"
  require_index "$rel"
  mkdir -p "$releases"

  if [[ -e "$live" && ! -L "$live" ]]; then
    if [[ ! -d "$live" ]]; then
      echo "public exists and is not a directory or a symlink: ${live}" >&2
      exit 1
    fi
    if [[ -e "${releases}/previous" ]]; then
      echo "Refusing to replace ${releases}/previous while migrating the live directory" >&2
      exit 1
    fi
    mv "$live" "${releases}/previous"
    previous="releases/previous"
    echo "Moved the existing public directory to ${releases}/previous"
  elif [[ -L "$live" ]]; then
    current_link="$(readlink "$live")"
    case "$current_link" in
      releases/*)
        previous="$current_link"
        ;;
      *)
        echo "public symlink must be relative (releases/<name>), found ${current_link}" >&2
        exit 1
        ;;
    esac
  fi

  if [[ -n "$previous" ]]; then
    assert_release_rel "previous" "$previous"
  fi
  flip_public "$rel"
  state_put "$previous" "$rel"
  echo "Published ${rel}"
}

rollback_release() {
  local previous current
  previous="$(state_get previous)"
  current="$(state_get current)"
  if [[ -z "$previous" ]]; then
    echo "No previous release to restore" >&2
    exit 1
  fi
  assert_release_rel "previous" "$previous"
  require_index "$previous"
  flip_public "$previous"
  state_put "$current" "$previous"
  echo "Restored ${previous}"
}

prune_releases() {
  local keep previous current name mtime
  local -a ranked=()
  keep="${KEEP_RELEASES:-5}"
  if [[ ! "$keep" =~ ^[0-9]+$ || "$keep" -lt 1 ]]; then
    echo "KEEP_RELEASES must be a positive whole number" >&2
    exit 1
  fi
  previous="$(state_get previous)"
  current="$(state_get current)"
  [[ -d "$releases" ]] || return 0
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    ranked+=("$name")
  done < <(
    for dir in "$releases"/*; do
      [[ -d "$dir" ]] || continue
      name="$(basename "$dir")"
      [[ "$name" =~ ^[0-9a-fA-F]{40}$ ]] || continue
      if mtime="$(stat -f %m "$dir" 2>/dev/null)"; then
        :
      else
        mtime="$(stat -c %Y "$dir")"
      fi
      printf '%s %s\n' "$mtime" "$name"
    done | sort -nr | awk '{print $2}'
  )
  if [[ "${#ranked[@]}" -eq 0 ]]; then
    return 0
  fi
  local index=0
  for name in "${ranked[@]}"; do
    local rel="releases/${name}"
    index=$((index + 1))
    if [[ "$index" -le "$keep" || "$rel" == "$current" || "$rel" == "$previous" ]]; then
      continue
    fi
    if [[ ! "$name" =~ ^[0-9a-fA-F]{40}$ || -z "$releases" || "$releases" == "/" ]]; then
      echo "Refusing to prune ${name}" >&2
      exit 1
    fi
    rm -rf -- "${releases:?}/${name:?}"
    echo "Pruned ${rel}"
  done
}

case "$action" in
  publish) publish_release ;;
  rollback) rollback_release ;;
  prune) prune_releases ;;
esac
