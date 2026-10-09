#!/usr/bin/env bash
# Compile a Flutter web app. Runs on the GitHub runner or a laptop, never on SiteHost.
set -euo pipefail

renderer="${WEB_RENDERER:-wasm}"
base_href="${BASE_HREF:-/}"
pwa_strategy="${PWA_STRATEGY:-none}"
source_maps="${SOURCE_MAPS:-false}"
dry_run="${DRY_RUN:-0}"
run_pub_get="${RUN_PUB_GET:-1}"

case "$renderer" in
  wasm|javascript) ;;
  *)
    echo "WEB_RENDERER must be wasm or javascript" >&2
    exit 1
    ;;
esac
if [[ "$base_href" != /* || "$base_href" != */ ]]; then
  echo "BASE_HREF must start and end with /" >&2
  exit 1
fi
if [[ ! "$pwa_strategy" =~ ^[a-z0-9-]+$ ]]; then
  echo "PWA_STRATEGY must be a Flutter pwa strategy such as none" >&2
  exit 1
fi

workspace="${GITHUB_WORKSPACE:-$(pwd)}"
if [[ -n "${PACKAGE_DIR:-}" ]]; then
  package="$PACKAGE_DIR"
elif [[ "${PACKAGE_PATH:-.}" == /* ]]; then
  package="$PACKAGE_PATH"
else
  package="${workspace}/${PACKAGE_PATH:-.}"
fi
if [[ -n "${PUB_GET_DIR:-}" ]]; then
  pub_get_dir="$PUB_GET_DIR"
elif [[ "${PUB_GET_PATH:-.}" == /* ]]; then
  pub_get_dir="$PUB_GET_PATH"
else
  pub_get_dir="${workspace}/${PUB_GET_PATH:-.}"
fi

if [[ ! -d "$package" ]]; then
  echo "Flutter package not found: ${package}" >&2
  exit 1
fi

define_source="${DART_DEFINE_FILE:-}"
if [[ -z "$define_source" && -f "${package}/config/production.json" ]]; then
  define_source="${package}/config/production.json"
fi

merged="$(mktemp)"
cleanup() {
  rm -f "$merged"
}
trap cleanup EXIT

if [[ "${GITHUB_ACTIONS:-}" == "true" && -n "${FLUTTER_DART_DEFINES:-}" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    if ((${#line} >= 8)); then
      echo "::add-mask::${line}"
    fi
  done <<< "$FLUTTER_DART_DEFINES"
fi

server_url="$(
  python3 - "$define_source" "$merged" <<'PY'
import json, os, sys

source, dest = sys.argv[1], sys.argv[2]
defines = {}
if source and os.path.isfile(source):
    with open(source, encoding="utf-8") as handle:
        loaded = json.load(handle)
    if not isinstance(loaded, dict):
        sys.exit("Dart define file must be a JSON object")
    defines.update(loaded)
raw = os.environ.get("FLUTTER_DART_DEFINES", "").strip()
if raw:
    overlay = json.loads(raw)
    if not isinstance(overlay, dict):
        sys.exit("FLUTTER_DART_DEFINES must be a JSON object")
    defines.update(overlay)
for key in (
    "SERVER_URL",
    "TALARIA_API_KEY",
    "TALARIA_DSN",
    "APP_ENV",
    "APP_RELEASE",
    "WEB_DASHBOARD_ORIGIN",
):
    value = os.environ.get(key, "")
    if value:
        defines[key] = value
server = str(defines.get("SERVER_URL", ""))
lower = server.lower()
if "localhost" in lower or "127.0.0.1" in lower:
    sys.exit("Refusing to build: SERVER_URL is local")
if (source or raw) and not server:
    sys.exit("SERVER_URL is missing from the dart defines")
with open(dest, "w", encoding="utf-8") as handle:
    json.dump(defines, handle)
    handle.write("\n")
print(server)
PY
)"

if [[ -n "$server_url" ]]; then
  echo "Compile-time SERVER_URL=${server_url}"
fi

args=(build web --release --base-href "$base_href" --pwa-strategy="$pwa_strategy")
if [[ "$renderer" == "wasm" ]]; then
  args+=(--wasm)
fi
if [[ "$source_maps" == "true" ]]; then
  args+=(--source-maps)
fi
if [[ -s "$merged" && "$merged" != "{}" ]]; then
  # The merged file may be "{}" when there is no define source. Skip that.
  if [[ "$(python3 -c 'import json,sys; print("yes" if json.load(open(sys.argv[1])) else "no")' "$merged")" == "yes" ]]; then
    args+=(--dart-define-from-file="$merged")
  fi
fi

echo "Building Flutter web (${renderer}) in ${package}"
if [[ "$dry_run" == "1" ]]; then
  echo "[dry-run] would run: flutter ${args[*]}"
  exit 0
fi

if ! command -v flutter >/dev/null 2>&1; then
  echo "flutter not found on PATH" >&2
  exit 1
fi

if [[ "$run_pub_get" == "1" ]]; then
  if [[ ! -d "$pub_get_dir" ]]; then
    echo "pub get directory not found: ${pub_get_dir}" >&2
    exit 1
  fi
  (cd "$pub_get_dir" && flutter pub get)
fi

(
  cd "$package"
  flutter "${args[@]}"
)

build_dir="${package}/build/web"
if [[ ! -f "${build_dir}/index.html" ]]; then
  echo "Build finished but ${build_dir}/index.html is missing" >&2
  exit 1
fi
if [[ ! -f "${build_dir}/main.dart.js" ]]; then
  echo "Build finished but ${build_dir}/main.dart.js is missing" >&2
  exit 1
fi
if [[ "$renderer" == "wasm" ]]; then
  if [[ ! -f "${build_dir}/main.dart.wasm" ]]; then
    echo "Wasm build finished but ${build_dir}/main.dart.wasm is missing" >&2
    exit 1
  fi
  if [[ ! -f "${build_dir}/main.dart.mjs" ]]; then
    echo "Wasm build finished but ${build_dir}/main.dart.mjs is missing" >&2
    exit 1
  fi
fi
