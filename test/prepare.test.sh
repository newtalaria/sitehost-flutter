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
mkdir -p "${tmp}/build/assets/fonts"
printf '%s\n' 'icon-font' > "${tmp}/build/assets/fonts/MaterialIcons-Regular.otf"
printf '%s\n' '[{"family":"MaterialIcons","fonts":[{"asset":"fonts/MaterialIcons-Regular.otf"}]}]' > "${tmp}/build/assets/FontManifest.json"
printf '%s\n' 'load FontManifest.json' > "${tmp}/build/main.dart.js"
printf '%s\n' 'load FontManifest.json' > "${tmp}/build/main.dart.wasm"
cat > "${tmp}/build/flutter_bootstrap.js" <<'EOF'
loadEntrypoint(e){let{entrypointUrl:s=m("main.dart.js")}=e||{};}
let a=e.mainJsPath??"main.dart.js";
_flutter.buildConfig = {"wasmHashes":{"main.dart.wasm":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"builds":[{"mainWasmPath":"main.dart.wasm","jsSupportRuntimePath":"main.dart.mjs"},{"mainJsPath":"main.dart.js"}]};
EOF

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
if ! grep -q 'fonts/MaterialIcons-aaaaaaa.otf' "${tmp}/build/assets/FontManifest.json"; then
  echo "icon font was not renamed in FontManifest.json" >&2
  cat "${tmp}/build/assets/FontManifest.json" >&2
  exit 1
fi
if [[ ! -f "${tmp}/build/assets/fonts/MaterialIcons-aaaaaaa.otf" ]]; then
  echo "renamed icon font file is missing" >&2
  exit 1
fi
if ! grep -q 'icon-font' "${tmp}/build/assets/fonts/MaterialIcons-aaaaaaa.otf"; then
  echo "renamed icon font has the wrong bytes" >&2
  exit 1
fi
if ! grep -q 'Font-aaaaaaa.json' "${tmp}/build/main.dart.js" "${tmp}/build/main.dart.wasm"; then
  echo "compiled app still requests FontManifest.json" >&2
  exit 1
fi
if grep -q 'FontManifest.json' "${tmp}/build/main.dart.js" "${tmp}/build/main.dart.wasm"; then
  echo "old manifest name remains in the compiled app" >&2
  exit 1
fi
if ! grep -q 'main.dart.wasm?v=aaaaaaa' "${tmp}/build/flutter_bootstrap.js"; then
  echo "wasm entry was not cache-busted" >&2
  exit 1
fi
if ! grep -q 'main.dart.js?v=aaaaaaa' "${tmp}/build/flutter_bootstrap.js"; then
  echo "js entry was not cache-busted" >&2
  exit 1
fi

BUILD_DIR="${tmp}/build" DEPLOY_SHA="$sha" bash "$prepare"
count="$(grep -o 'flutter_bootstrap.js?v=aaaaaaa' "${tmp}/build/index.html" | wc -l | tr -d ' ')"
if [[ "$count" != "1" ]]; then
  echo "second prepare duplicated the cache bust" >&2
  exit 1
fi

echo "prepare test passed"
