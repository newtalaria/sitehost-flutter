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

# Icon font and FontManifest.json keep the same URL every release. Browsers that
# stored either response as immutable never revalidate, so each release publishes
# a new font filename and a new manifest filename, and the compiled app asks for
# that manifest. The manifest name stays 17 characters so the Wasm string length
# does not change.
python3 - "$BUILD_DIR" "$short" <<'PY'
import hashlib, re, shutil, sys
from pathlib import Path

build, short = Path(sys.argv[1]), sys.argv[2]
manifest_name = "FontManifest.json"
release_manifest = f"Font-{short}.json"
if len(release_manifest) != len(manifest_name):
    sys.exit(f"{release_manifest} must be {len(manifest_name)} characters")

manifest = build / "assets" / manifest_name
if manifest.is_file():
    text = manifest.read_text(encoding="utf-8")
    target = f"fonts/MaterialIcons-{short}.otf"
    if target not in text:
        match = re.search(r"fonts/MaterialIcons-[A-Za-z0-9]+\.otf", text)
        if not match:
            sys.exit("FontManifest.json has no MaterialIcons font")
        old_rel = match.group(0)
        old_file = build / "assets" / old_rel
        new_file = build / "assets" / target
        if not old_file.is_file():
            sys.exit(f"missing {old_file}")
        new_file.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(old_file, new_file)
        text = text.replace(old_rel, target, 1)
        manifest.write_text(text, encoding="utf-8")
    (build / "assets" / release_manifest).write_text(text, encoding="utf-8")
    print(target)
    print(release_manifest)

    old_b, new_b = manifest_name.encode(), release_manifest.encode()
    for name in ("main.dart.js", "main.dart.wasm", "main.dart.mjs"):
        path = build / name
        if not path.is_file():
            continue
        data = path.read_bytes()
        count = data.count(old_b)
        if count == 0:
            if new_b not in data:
                print(f"{name}: no {manifest_name}")
            continue
        path.write_bytes(data.replace(old_b, new_b))
        print(f"{name}: {count} {release_manifest}")

bootstrap = build / "flutter_bootstrap.js"
if bootstrap.is_file():
    boot = bootstrap.read_text(encoding="utf-8")
    replacements = {
        'm("main.dart.js")': f'm("main.dart.js?v={short}")',
        '??"main.dart.js"': f'??"main.dart.js?v={short}"',
        '"mainJsPath":"main.dart.js"': f'"mainJsPath":"main.dart.js?v={short}"',
        '"mainWasmPath":"main.dart.wasm"': f'"mainWasmPath":"main.dart.wasm?v={short}"',
        '"jsSupportRuntimePath":"main.dart.mjs"': f'"jsSupportRuntimePath":"main.dart.mjs?v={short}"',
    }
    for old, new in replacements.items():
        if old in boot:
            boot = boot.replace(old, new)
    wasm = build / "main.dart.wasm"
    if wasm.is_file():
        digest = hashlib.sha256(wasm.read_bytes()).hexdigest()
        boot, n = re.subn(
            r'("main\.dart\.wasm":")[0-9a-f]{64}(")',
            rf"\g<1>{digest}\2",
            boot,
            count=1,
        )
        if n == 1:
            print(f"main.dart.wasm hash {digest[:12]}")
    bootstrap.write_text(boot, encoding="utf-8")
    print(f"entrypoint ?v={short}")
PY

echo "Prepared ${BUILD_DIR}"
