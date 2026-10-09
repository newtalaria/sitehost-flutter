#!/usr/bin/env bash
# Publishing flips a relative symlink, rollback restores it, and prune drops old shas.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
publish="${root}/actions/ssh/remote-publish.sh"
tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

app="${tmp}/app"
sha1="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
sha2="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
sha3="cccccccccccccccccccccccccccccccccccccccc"
sha4="dddddddddddddddddddddddddddddddddddddddd"

seed() {
  local sha="$1"
  local body="$2"
  mkdir -p "${app}/releases/${sha}"
  printf '%s\n' "$body" > "${app}/releases/${sha}/index.html"
}

mkdir -p "${app}/public"
printf '%s\n' 'legacy' > "${app}/public/index.html"
seed "$sha1" "one"

SITEHOST_APP_PATH="$app" DEPLOY_SHA="$sha1" PUBLISH_ACTION=publish bash "$publish"
if [[ "$(readlink "${app}/public")" != "releases/${sha1}" ]]; then
  echo "public did not point at the first release" >&2
  exit 1
fi
if [[ "$(cat "${app}/public/index.html")" != "one" ]]; then
  echo "public did not serve the first release" >&2
  exit 1
fi
if [[ ! -f "${app}/releases/previous/index.html" ]]; then
  echo "legacy public directory was not moved aside" >&2
  exit 1
fi

seed "$sha2" "two"
SITEHOST_APP_PATH="$app" DEPLOY_SHA="$sha2" PUBLISH_ACTION=publish bash "$publish"
if [[ "$(cat "${app}/public/index.html")" != "two" ]]; then
  echo "public did not serve the second release" >&2
  exit 1
fi

SITEHOST_APP_PATH="$app" PUBLISH_ACTION=rollback bash "$publish"
if [[ "$(readlink "${app}/public")" != "releases/${sha1}" ]]; then
  echo "rollback did not restore the first release" >&2
  exit 1
fi
if [[ "$(cat "${app}/public/index.html")" != "one" ]]; then
  echo "rollback did not serve the first release" >&2
  exit 1
fi

old1="1111111111111111111111111111111111111111"
old2="2222222222222222222222222222222222222222"
seed "$old1" "old"
seed "$old2" "older"
touch -t 202001010000 "${app}/releases/${old1}" "${app}/releases/${old2}"
seed "$sha3" "three"
seed "$sha4" "four"
SITEHOST_APP_PATH="$app" KEEP_RELEASES=2 PUBLISH_ACTION=prune bash "$publish"
if [[ ! -d "${app}/releases/${sha1}" || ! -d "${app}/releases/${sha2}" ]]; then
  echo "prune deleted the current or previous release" >&2
  exit 1
fi
if [[ -d "${app}/releases/${old1}" || -d "${app}/releases/${old2}" ]]; then
  echo "prune left an old release in place" >&2
  exit 1
fi

echo "publish test passed"
