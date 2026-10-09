# Flutter web deploy on SiteHost

Builds a Flutter web app on GitHub Actions, then SSHes into a stock Nginx + PHP container and publishes the static files. The container does not get a Flutter SDK.

Pin `@v1`.

Wasm is the default. `flutter build web --wasm` writes a Wasm build and a JavaScript build into one directory. Chromium runs Wasm. Firefox, Safari, and every iOS browser run the JavaScript build. Pass `web_renderer: javascript` to compile JavaScript only.

The container stays on the free **Nginx + PHP 8.5** image. A custom image that dropped PHP would cost $20. That image is deferred. See the dashboard note in `platform/deploy/sitehost/flutter_web.md`.

## Set up a site

Secrets and variables follow the Silverstripe deploy. If that action is already in the organisation, reuse `SITEHOST_SSH_PRIVATE_KEY`, `SITEHOST_SSH_HOST`, `SITEHOST_SSH_HOST_FINGERPRINT`, and `SITEHOST_SSH_PORT`. The Silverstripe README has the key ceremony.

Create a GitHub environment per container (`production`, and `test` when there is one). Put these variables on the environment:

| Name | When | Example |
| --- | --- | --- |
| `SITEHOST_SSH_USER` | Every deploy | `example` |
| `SITEHOST_SITE_URL` | Every deploy | `https://one.newtalaria.com` |

`SITEHOST_SITE_URL` must start with `http://` or `https://`.

| Name | Default |
| --- | --- |
| `SITEHOST_APP_PATH` | `/container/application` |

Optional secret `FLUTTER_DART_DEFINES`: a JSON object of compile-time defines. Keys in the secret replace the same keys in the package file (`config/production.json` when that file exists). `APP_RELEASE` is set to `<ref>@<short-sha>` and wins over both. A `SERVER_URL` that contains `localhost` or `127.0.0.1` fails the build.

`TALARIA_RELEASE_KEY` is required only when `upload_source_maps` is true. It needs `releases:write`. The uploader accepts `*.js.map`. Wasm `.wasm.map` files are deleted from the published tree and are not uploaded.

The SSH user must be able to write `/container/config/nginx` and reload Nginx. Leave the config directory writable when you create the user.

## Add the workflow

Save this as `.github/workflows/deploy.yml` in the app repository. Pass the keys by name. `secrets: inherit` does not reach a reusable workflow in another organisation.

```yaml
name: Deploy Flutter to SiteHost

on:
  workflow_dispatch:
    inputs:
      environment:
        description: Container to deploy
        type: choice
        required: true
        options:
          - production
      emergency_override:
        description: Production only. Deploy a ref that is not main or a tag.
        type: boolean
        default: false
      web_renderer:
        description: wasm or javascript
        type: choice
        required: true
        default: wasm
        options:
          - wasm
          - javascript

permissions:
  contents: read

jobs:
  deploy:
    uses: newtalaria/sitehost-flutter/.github/workflows/deploy.yml@v1
    with:
      environment: ${{ inputs.environment }}
      emergency_override: ${{ inputs.emergency_override }}
      require_main_or_tag: ${{ inputs.environment == 'production' }}
      web_renderer: ${{ inputs.web_renderer }}
      flutter_version: "3.47.5"
      package_path: .
      pub_get_path: .
      base_href: /
    secrets:
      SITEHOST_SSH_PRIVATE_KEY: ${{ secrets.SITEHOST_SSH_PRIVATE_KEY }}
      FLUTTER_DART_DEFINES: ${{ secrets.FLUTTER_DART_DEFINES }}
      TALARIA_RELEASE_KEY: ${{ secrets.TALARIA_RELEASE_KEY }}
```

A workspace package sets `package_path` to the app directory and `pub_get_path` to the workspace root. The Talaria dashboard uses `package_path: new_talaria_flutter` and `pub_get_path: .`.

The shared workflow queues deploys with group `sitehost-flutter-${{ github.repository }}-${{ inputs.environment }}`. Leave that group off the caller. GitHub cancels the run as a deadlock when the caller and the called workflow lock one group.

## What each run does

1. Check out the app and compile `flutter build web` on the runner. `--pwa-strategy=none` is the default, because a leftover service worker has served a stale page after a deploy.
2. SSH in and install hosting if it is missing or out of date: Wasm and `.mjs` MIME types, the SPA `try_files` rule, `Cross-Origin-Opener-Policy: same-origin`, and `Cross-Origin-Embedder-Policy: credentialless`. `credentialless` is what lets the page call another host, such as `api.newtalaria.com`. Then `nginx -t` and reload. A failed test restores the previous Nginx files. PHP is not restarted.
3. Upload the build to `/container/application/releases/<sha>/`.
4. Cache-bust `flutter_bootstrap.js?v=<short-sha>` and delete source maps and `flutter_service_worker.js` before the upload.
5. Point `public` at that release. The first run moves an existing `public` directory to `releases/previous`.
6. Request `SITEHOST_SITE_URL`, including `/issues/smoke`, and check Wasm content types and the isolation headers when the renderer is `wasm`.
7. On smoke failure, point `public` back at the previous release.

`index.html`, `flutter.js`, `flutter_bootstrap.js`, `main.dart.js`, `main.dart.wasm`, `main.dart.mjs`, `FontManifest.json`, and the unhashed icon font are `Cache-Control: no-cache`. A Cloudflare cache rule that marks `.otf` or `FontManifest.json` immutable will keep serving the old icon font. Do not add that rule. A Wasm binary cannot be patched to a longer font filename.

## Inputs

| Input | Default | Effect |
| --- | --- | --- |
| `environment` | required | GitHub environment for this container. |
| `web_renderer` | `wasm` | `wasm` or `javascript`. |
| `flutter_version` | `3.47.5` | Flutter SDK on the runner. |
| `package_path` | `.` | Flutter package, relative to the repository. |
| `pub_get_path` | `.` | Where `flutter pub get` runs. |
| `base_href` | `/` | Must start and end with `/`. |
| `pwa_strategy` | `none` | Passed to `flutter build web`. |
| `upload_source_maps` | `false` | Build and upload `*.js.map`, then omit maps from the publish. |
| `keep_releases` | `5` | Sha directories kept under `releases/`. |
| `require_main_or_tag` | `false` | Fail unless the ref is `main` or a tag. |
| `test_rollback` | `false` | Finish the deploy, then restore the previous release. |
