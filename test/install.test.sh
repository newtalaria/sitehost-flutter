#!/usr/bin/env bash
# The hosting install is idempotent, and a failed reload restores the previous files.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
install="${root}/actions/ssh/remote-install.sh"
site="${root}/nginx/flutter-web.conf"
tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

prepare_tree() {
  local dir="$1"
  mkdir -p "${dir}/nginx/sites-available" "${dir}/nginx/sites-enabled" "${dir}/application"
  printf '%s\n' 'application/javascript			js;' > "${dir}/nginx/mime.types"
}

run_install() {
  local dir="$1"
  local reload="$2"
  SITEHOST_APP_PATH="${dir}/application" \
    NGINX_MIME_TYPES="${dir}/nginx/mime.types" \
    NGINX_SITE_FILE="${dir}/nginx/sites-available/default" \
    NGINX_SITE_ENABLED="${dir}/nginx/sites-enabled/default" \
    FLUTTER_NGINX_SITE_FILE="$site" \
    NGINX_RELOAD_COMMAND="$reload" \
    bash "$install"
}

prepare_tree "$tmp"
run_install "$tmp" "touch ${tmp}/reloaded"
if [[ ! -f "${tmp}/reloaded" ]]; then
  echo "install did not reload nginx" >&2
  exit 1
fi
if ! grep -q 'application/wasm' "${tmp}/nginx/mime.types"; then
  echo "mime.types is missing application/wasm" >&2
  exit 1
fi
if ! grep -q 'mjs;' "${tmp}/nginx/mime.types"; then
  echo "mime.types is missing mjs" >&2
  exit 1
fi
installed="${tmp}/nginx/sites-available/default"
if ! grep -q 'credentialless' "$installed"; then
  echo "site file is missing credentialless" >&2
  exit 1
fi
if ! grep -q 'application/wasm' "$installed"; then
  echo "site file is missing application/wasm" >&2
  exit 1
fi
if ! grep -q "root ${tmp}/application/public;" "$installed"; then
  echo "site file did not set the public root" >&2
  exit 1
fi
if grep -q '__PUBLIC_ROOT__' "$installed"; then
  echo "site file still contains the public root placeholder" >&2
  exit 1
fi
if [[ ! -L "${tmp}/nginx/sites-enabled/default" ]]; then
  echo "sites-enabled/default was not linked" >&2
  exit 1
fi

rm -f "${tmp}/reloaded"
second="$(run_install "$tmp" "touch ${tmp}/reloaded")"
if [[ -f "${tmp}/reloaded" ]]; then
  echo "second install reloaded nginx" >&2
  exit 1
fi
if [[ "$second" != *"Nginx config unchanged"* ]]; then
  echo "second install did not report an unchanged config" >&2
  echo "$second" >&2
  exit 1
fi

fail_dir="${tmp}/fail"
prepare_tree "$fail_dir"
set +e
SITEHOST_APP_PATH="${fail_dir}/application" \
  NGINX_MIME_TYPES="${fail_dir}/nginx/mime.types" \
  NGINX_SITE_FILE="${fail_dir}/nginx/sites-available/default" \
  NGINX_SITE_ENABLED="${fail_dir}/nginx/sites-enabled/default" \
  FLUTTER_NGINX_SITE_FILE="$site" \
  NGINX_RELOAD_COMMAND="false" \
  bash "$install" >"${tmp}/fail.out" 2>"${tmp}/fail.err"
status=$?
set -e
if [[ "$status" -eq 0 ]]; then
  echo "failed reload was treated as success" >&2
  exit 1
fi
if grep -q 'application/wasm' "${fail_dir}/nginx/mime.types"; then
  echo "failed reload left the mime type change in place" >&2
  exit 1
fi
if [[ -e "${fail_dir}/nginx/sites-available/default" ]]; then
  echo "failed reload left the new site file in place" >&2
  exit 1
fi
if [[ -e "${fail_dir}/nginx/sites-enabled/default" ]]; then
  echo "failed reload left the sites-enabled link in place" >&2
  exit 1
fi

pid_dir="${tmp}/pid-case"
prepare_tree "$pid_dir"
bin_dir="${tmp}/bin"
mkdir -p "$bin_dir"
cat > "${bin_dir}/nginx" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-t" ]]; then
  echo "nginx: the configuration file /etc/nginx/nginx.conf syntax is ok" >&2
  echo 'open() "/run/nginx.pid" failed (13: Permission denied)' >&2
  echo "nginx: configuration file /etc/nginx/nginx.conf test failed" >&2
  exit 1
fi
exit 1
EOF
cat > "${bin_dir}/supervisorctl" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "signal" && "\${2:-}" == "HUP" && "\${3:-}" == "nginx" ]]; then
  touch "${tmp}/signalled"
  echo "nginx: signalled"
  exit 0
fi
exit 1
EOF
chmod +x "${bin_dir}/nginx" "${bin_dir}/supervisorctl"
PATH="${bin_dir}:${PATH}" \
  SITEHOST_APP_PATH="${pid_dir}/application" \
  NGINX_MIME_TYPES="${pid_dir}/nginx/mime.types" \
  NGINX_SITE_FILE="${pid_dir}/nginx/sites-available/default" \
  NGINX_SITE_ENABLED="${pid_dir}/nginx/sites-enabled/default" \
  FLUTTER_NGINX_SITE_FILE="$site" \
  NGINX_BIN="${bin_dir}/nginx" \
  bash "$install" >"${tmp}/pid.out" 2>"${tmp}/pid.err"
if [[ ! -f "${tmp}/signalled" ]]; then
  echo "pid permission failure did not reload nginx through supervisor" >&2
  cat "${tmp}/pid.out" "${tmp}/pid.err" >&2
  exit 1
fi
if ! grep -q 'credentialless' "${pid_dir}/nginx/sites-available/default"; then
  echo "pid permission failure restored the new site file" >&2
  exit 1
fi

echo "install test passed"
