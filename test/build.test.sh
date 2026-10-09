#!/usr/bin/env bash
# build-web.sh refuses a local SERVER_URL and passes wasm to flutter.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
build="${root}/actions/build/build-web.sh"
tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

mkdir -p "${tmp}/bin" "${tmp}/pkg/config"
cat > "${tmp}/bin/flutter" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$FLUTTER_ARGS_FILE"
mkdir -p build/web
printf '%s\n' '<script src="flutter_bootstrap.js" async></script>' > build/web/index.html
printf '%s\n' 'main' > build/web/main.dart.js
if [[ "$*" == *"--wasm"* ]]; then
  printf '%s\n' 'wasm' > build/web/main.dart.wasm
  printf '%s\n' 'mjs' > build/web/main.dart.mjs
fi
EOF
chmod +x "${tmp}/bin/flutter"

printf '%s\n' '{"SERVER_URL":"http://localhost:8080/","APP_ENV":"production"}' > "${tmp}/pkg/config/production.json"
set +e
PATH="${tmp}/bin:${PATH}" \
  PACKAGE_DIR="${tmp}/pkg" \
  RUN_PUB_GET=0 \
  WEB_RENDERER=wasm \
  bash "$build" >"${tmp}/local.out" 2>"${tmp}/local.err"
status=$?
set -e
if [[ "$status" -eq 0 ]]; then
  echo "localhost SERVER_URL was accepted" >&2
  exit 1
fi
if ! grep -q 'SERVER_URL is local' "${tmp}/local.err"; then
  echo "localhost refusal did not explain why" >&2
  cat "${tmp}/local.err" >&2
  exit 1
fi

printf '%s\n' '{"SERVER_URL":"https://api.newtalaria.com/","APP_ENV":"production"}' > "${tmp}/pkg/config/production.json"
PATH="${tmp}/bin:${PATH}" \
  PACKAGE_DIR="${tmp}/pkg" \
  PUB_GET_DIR="${tmp}/pkg" \
  RUN_PUB_GET=0 \
  WEB_RENDERER=wasm \
  APP_RELEASE="main@abc1234" \
  FLUTTER_ARGS_FILE="${tmp}/args" \
  bash "$build"
if ! grep -q -- '--wasm' "${tmp}/args"; then
  echo "wasm renderer did not pass --wasm" >&2
  cat "${tmp}/args" >&2
  exit 1
fi
if ! grep -q -- '--pwa-strategy=none' "${tmp}/args"; then
  echo "build did not disable the service worker" >&2
  exit 1
fi
if ! grep -q -- '--dart-define-from-file=' "${tmp}/args"; then
  echo "build did not pass dart defines" >&2
  exit 1
fi

# Confirm the merged defines contained the release. The define file is removed on exit.
cat > "${tmp}/bin/flutter" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$FLUTTER_ARGS_FILE"
for arg in "$@"; do
  case "$arg" in
    --dart-define-from-file=*)
      cp "${arg#--dart-define-from-file=}" "$FLUTTER_DEFINES_COPY"
      ;;
  esac
done
mkdir -p build/web
printf '%s\n' '<script src="flutter_bootstrap.js" async></script>' > build/web/index.html
printf '%s\n' 'main' > build/web/main.dart.js
printf '%s\n' 'wasm' > build/web/main.dart.wasm
printf '%s\n' 'mjs' > build/web/main.dart.mjs
EOF
chmod +x "${tmp}/bin/flutter"
PATH="${tmp}/bin:${PATH}" \
  PACKAGE_DIR="${tmp}/pkg" \
  RUN_PUB_GET=0 \
  WEB_RENDERER=javascript \
  APP_RELEASE="main@abc1234" \
  FLUTTER_ARGS_FILE="${tmp}/args" \
  FLUTTER_DEFINES_COPY="${tmp}/defines.json" \
  bash "$build"
if grep -q -- '--wasm' "${tmp}/args"; then
  echo "javascript renderer passed --wasm" >&2
  exit 1
fi
if ! grep -q 'main@abc1234' "${tmp}/defines.json"; then
  echo "APP_RELEASE was not written into the dart defines" >&2
  exit 1
fi
if grep -q 'TALARIA_API_KEY' "${tmp}/args"; then
  echo "flutter arguments included a define value" >&2
  exit 1
fi

echo "build test passed"
