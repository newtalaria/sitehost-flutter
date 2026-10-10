#!/usr/bin/env bash
# Install Flutter web hosting on a stock Nginx + PHP container.
# Idempotent: a second run that finds the same files does not reload Nginx.
set -euo pipefail

if [[ -z "${SITEHOST_LIB_LOADED:-}" ]]; then
  # shellcheck disable=SC1091
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
fi

: "${SITEHOST_APP_PATH:?SITEHOST_APP_PATH is required}"

echo "Remote Flutter hosting install started"

mime_file="${NGINX_MIME_TYPES:-/container/config/nginx/mime.types}"
site_file="${NGINX_SITE_FILE:-/container/config/nginx/sites-available/default}"
enabled_file="${NGINX_SITE_ENABLED:-/container/config/nginx/sites-enabled/default}"
public_root="${SITEHOST_APP_PATH}/public"
changed=0
mime_bak=""
site_bak=""
enabled_bak=""
had_site=0
had_enabled=0
enabled_existed=0
enabled_was_link=0
enabled_link_target=""
rendered=""

cleanup() {
  rm -f "$mime_bak" "$site_bak" "$enabled_bak" "$rendered"
}
trap cleanup EXIT

# Put the previous files back when nginx -t or the reload fails.
restore_config() {
  if [[ -n "$mime_bak" && -f "$mime_bak" ]]; then
    cp "$mime_bak" "$mime_file"
  fi
  if [[ "$had_site" -eq 1 && -n "$site_bak" && -f "$site_bak" ]]; then
    cp "$site_bak" "$site_file"
  elif [[ "$had_site" -eq 0 ]]; then
    rm -f "$site_file"
  fi
  if [[ "$enabled_was_link" -eq 1 ]]; then
    ln -sfn "$enabled_link_target" "$enabled_file"
  elif [[ "$had_enabled" -eq 1 && -n "$enabled_bak" && -f "$enabled_bak" ]]; then
    cp "$enabled_bak" "$enabled_file"
  elif [[ "$enabled_existed" -eq 0 ]]; then
    rm -f "$enabled_file"
  fi
}

mime_has_ext() {
  local ext="$1"
  grep -Eq "(^|[[:space:]])${ext};" "$mime_file"
}

write_if_different() {
  local dest="$1"
  local src="$2"
  if [[ -f "$dest" ]] && cmp -s "$dest" "$src"; then
    return 0
  fi
  cp "$src" "$dest"
  changed=1
}

assert_absolute_path "SITEHOST_APP_PATH" "$SITEHOST_APP_PATH"
assert_absolute_path "NGINX_MIME_TYPES" "$mime_file"
assert_absolute_path "NGINX_SITE_FILE" "$site_file"

if [[ ! -f "$mime_file" ]]; then
  echo "mime.types not found at ${mime_file}. The SSH user needs a writable Nginx config." >&2
  exit 1
fi
if [[ ! -d "$(dirname "$site_file")" ]]; then
  echo "Nginx site directory not found: $(dirname "$site_file")" >&2
  exit 1
fi

rendered="$(mktemp)"
if [[ -n "${FLUTTER_NGINX_SITE_FILE:-}" ]]; then
  if [[ ! -f "$FLUTTER_NGINX_SITE_FILE" ]]; then
    echo "FLUTTER_NGINX_SITE_FILE does not exist" >&2
    exit 1
  fi
  cp "$FLUTTER_NGINX_SITE_FILE" "$rendered"
elif [[ -n "${FLUTTER_NGINX_SITE_B64:-}" ]]; then
  printf '%s' "$FLUTTER_NGINX_SITE_B64" | base64 -d > "$rendered"
else
  echo "FLUTTER_NGINX_SITE_B64 is required" >&2
  exit 1
fi

if ! grep -q '__PUBLIC_ROOT__' "$rendered"; then
  echo "The Nginx site file is missing __PUBLIC_ROOT__" >&2
  exit 1
fi
if ! grep -q 'talaria-flutter-web' "$rendered"; then
  echo "Refusing to install a site file that is not the Flutter web config" >&2
  exit 1
fi

site_body="$(cat "$rendered")"
site_body="${site_body//__PUBLIC_ROOT__/$public_root}"
printf '%s\n' "$site_body" > "$rendered"
if grep -q '__PUBLIC_ROOT__' "$rendered"; then
  echo "Failed to set the Nginx root" >&2
  exit 1
fi

mime_bak="$(mktemp)"
cp "$mime_file" "$mime_bak"
if [[ -f "$site_file" ]]; then
  had_site=1
  site_bak="$(mktemp)"
  cp "$site_file" "$site_bak"
fi
if [[ -L "$enabled_file" ]]; then
  enabled_existed=1
  enabled_was_link=1
  enabled_link_target="$(readlink "$enabled_file")"
elif [[ -e "$enabled_file" ]]; then
  enabled_existed=1
  had_enabled=1
  enabled_bak="$(mktemp)"
  cp "$enabled_file" "$enabled_bak"
fi

need_mjs=0
need_wasm=0
if ! mime_has_ext "mjs"; then
  need_mjs=1
fi
if ! mime_has_ext "wasm"; then
  need_wasm=1
fi
if [[ "$need_mjs" -eq 1 || "$need_wasm" -eq 1 ]]; then
  {
    printf '%s\n' '# talaria-flutter-web'
    if [[ "$need_mjs" -eq 1 ]]; then
      printf 'application/javascript\tmjs;\n'
    fi
    if [[ "$need_wasm" -eq 1 ]]; then
      printf 'application/wasm\twasm;\n'
    fi
  } >> "$mime_file"
  changed=1
  echo "Updated ${mime_file}"
fi

write_if_different "$site_file" "$rendered"
if [[ -d "$(dirname "$enabled_file")" ]]; then
  if [[ -L "$enabled_file" ]]; then
    if [[ ! -f "$enabled_file" ]] || ! cmp -s "$enabled_file" "$rendered"; then
      ln -sfn "$site_file" "$enabled_file"
      changed=1
    fi
  elif [[ ! -e "$enabled_file" ]]; then
    ln -sfn "$site_file" "$enabled_file"
    changed=1
  else
    write_if_different "$enabled_file" "$rendered"
  fi
fi

if [[ "$changed" -eq 0 ]]; then
  echo "Nginx config unchanged"
  exit 0
fi

reload_nginx() {
  if [[ -n "${NGINX_RELOAD_COMMAND:-}" ]]; then
    bash --noprofile --norc -c "$NGINX_RELOAD_COMMAND"
    return
  fi
  local bin="${NGINX_BIN:-}"
  if [[ -z "$bin" ]]; then
    bin="$(command -v nginx || true)"
  fi
  if [[ -z "$bin" && -x /usr/sbin/nginx ]]; then
    bin=/usr/sbin/nginx
  fi
  if [[ -z "$bin" ]]; then
    echo "nginx is not on PATH, so the new config was not reloaded." >&2
    return 1
  fi
  local test_out test_status
  set +e
  test_out="$("$bin" -t 2>&1)"
  test_status=$?
  set -e
  printf '%s\n' "$test_out"
  if [[ "$test_status" -ne 0 ]]; then
    # syntax is ok, then nginx tries to create the pid file. The container
    # user cannot write /run/nginx.pid, so -t exits even when the config is valid.
    if ! printf '%s\n' "$test_out" | grep -q 'syntax is ok' \
      || ! printf '%s\n' "$test_out" | grep -Eq 'nginx\.pid" failed'; then
      echo "nginx -t failed. The previous config was restored." >&2
      return 1
    fi
  fi
  if "$bin" -s reload; then
    return 0
  fi
  if command -v supervisorctl >/dev/null 2>&1; then
    supervisorctl signal HUP nginx && return 0
    supervisorctl restart nginx && return 0
  fi
  echo "Could not reload nginx." >&2
  return 1
}

if ! reload_nginx; then
  restore_config
  exit 1
fi

echo "Installed Flutter web hosting and reloaded Nginx"
