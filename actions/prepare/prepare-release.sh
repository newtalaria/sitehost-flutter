#!/usr/bin/env bash
# Cache-bust flutter_bootstrap.js and drop files that must not be published.
set -euo pipefail

: "${BUILD_DIR:?BUILD_DIR is required}"
: "${DEPLOY_SHA:?DEPLOY_SHA is required}"

if [[ ! "$DEPLOY_SHA" =~ ^[0-9a-fA-F]{40}$ ]]; then
  echo "DEPLOY_SHA must be a 40 character git commit" >&2
  exit 1
fi
if [[ ! -f "${BUILD_DIR}/index.html" ]]; then
  echo "Missing ${BUILD_DIR}/index.html" >&2
  exit 1
fi

short="${DEPLOY_SHA:0:7}"
python3 - "$BUILD_DIR/index.html" "$short" <<'PY'
import re, sys

path, short = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8").read()
pattern = re.compile(r"""src=(["'])(?:\./)?flutter_bootstrap\.js(?:\?[^"']*)?\1""")
found = len(pattern.findall(text))
if found != 1:
    sys.exit(f"index.html has no single flutter_bootstrap.js script (found {found})")
replacement = f"src=\\1flutter_bootstrap.js?v={short}\\1"
updated = pattern.sub(replacement, text, count=1)
open(path, "w", encoding="utf-8").write(updated)
print(f"flutter_bootstrap.js?v={short}")
PY

rm -f "${BUILD_DIR}/flutter_service_worker.js"
find "$BUILD_DIR" -type f -name '*.map' -delete
echo "Prepared ${BUILD_DIR}"
