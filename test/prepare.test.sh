#!/usr/bin/env bash
# prepare-release.sh cache-busts the bootstrap script and drops maps and the service worker.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
prepare="${root}/actions/prepare/prepare-release.sh"
tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

sha="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
mkdir -p "${tmp}/build/assets"
cat > "${tmp}/build/index.html" <<'EOF'
<!DOCTYPE html>
<html>
<body>
  <script src="flutter_bootstrap.js" async></script>
</body>
</html>
EOF
printf '%s\n' 'worker' > "${tmp}/build/flutter_service_worker.js"
printf '%s\n' 'map' > "${tmp}/build/main.dart.js.map"
printf '%s\n' 'wasmmap' > "${tmp}/build/main.dart.wasm.map"

BUILD_DIR="${tmp}/build" DEPLOY_SHA="$sha" bash "$prepare"
if ! grep -q 'flutter_bootstrap.js?v=aaaaaaa' "${tmp}/build/index.html"; then
  echo "bootstrap script was not cache-busted" >&2
  cat "${tmp}/build/index.html" >&2
  exit 1
fi
if [[ -e "${tmp}/build/flutter_service_worker.js" ]]; then
  echo "service worker was not removed" >&2
  exit 1
fi
if [[ -e "${tmp}/build/main.dart.js.map" || -e "${tmp}/build/main.dart.wasm.map" ]]; then
  echo "source maps were not removed" >&2
  exit 1
fi

BUILD_DIR="${tmp}/build" DEPLOY_SHA="$sha" bash "$prepare"
count="$(grep -o 'flutter_bootstrap.js?v=aaaaaaa' "${tmp}/build/index.html" | wc -l | tr -d ' ')"
if [[ "$count" != "1" ]]; then
  echo "second prepare duplicated the cache bust" >&2
  exit 1
fi

echo "prepare test passed"
