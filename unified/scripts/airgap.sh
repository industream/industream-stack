#!/usr/bin/env bash
# =============================================================================
# airgap.sh — build and verify an offline bundle for a site with no internet.
# =============================================================================
#   ./airgap.sh prepare --runtime swarm --edition ee --out /media/usb
#   ./airgap.sh verify  /media/usb/industream-airgap-<commit>-ee-swarm
#
# Design: docs/specs/2026-09-03-airgap-bundle-design.md
# The image set ALWAYS comes from `deploy.sh --list-images` — never a second
# list, which would drift the first time a group is added.
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # unified/
REPO="$(cd "$HERE/.." && pwd)"

# GROUP_SET, not GROUPS: bash's builtin $GROUPS (the caller's group-ID list) silently
# swallows assignments — this exact collision already bit deploy.sh once (fixed there
# the same way; see the deploy-unification history). Never reintroduce it here.
RUNTIME="" EDITION="ce" ENV="prod" GROUP_SET="" OUT="." HARVEST_FROM=""
# --harvest-project: compose has no fixed volume-naming convention the way the
# swarm overlays do (`name: ${ENV}-<volume>`, deterministic) — deploy.sh treats
# --project as an arbitrary value unrelated to --env, so guessing it from $ENV
# would only coincidentally match. Empty means "assume it matched $ENV".
HARVEST_PROJECT=""
MAX_PART_SIZE="3800M" SKIP_IMAGES=false SKIP_ASSETS=false
# --bundle picks releases/bundle-platform-<ver>/ — same meaning as deploy.sh's
# --bundle. Defaulted here (rather than left to deploy.sh's own auto-select) so
# a repo with more than one release bundle checked out still resolves without
# extra flags.
BUNDLE="1.0.1"

die() { echo "✗ $*" >&2; exit 1; }

# deploy.sh requires --stack (swarm) / --project (compose) unconditionally, even
# for --list-images / --print-groups. airgap.sh never deploys, so the value only
# has to satisfy that guard — shared here so cmd_prepare, group_names, and
# images_for_group never re-derive it separately.
deploy_scope_args() {
  if [[ "$RUNTIME" == swarm ]]; then echo --stack airgap-list-images
  else echo --project airgap-list-images; fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --runtime)        RUNTIME="$2"; shift 2 ;;
      --edition)        EDITION="$2"; shift 2 ;;
      --env)            ENV="$2"; shift 2 ;;
      --bundle)         BUNDLE="$2"; shift 2 ;;
      --groups)         GROUP_SET="$2"; shift 2 ;;
      --out)            OUT="$2"; shift 2 ;;
      --max-part-size)  MAX_PART_SIZE="$2"; shift 2 ;;
      # Only the CDN-package harvest uses this: it points at the docker context
      # holding a warmed, connected instance. Grafana plugins only ever need
      # internet access, which the build machine has by definition, so the
      # plugin harvest always uses the local daemon and ignores this flag.
      --harvest-from)   HARVEST_FROM="$2"; shift 2 ;;
      --harvest-project) HARVEST_PROJECT="$2"; shift 2 ;;
      --skip-images)    SKIP_IMAGES=true; shift ;;
      --skip-assets)    SKIP_ASSETS=true; shift ;;
      *) die "unknown option: $1" ;;
    esac
  done
}

cmd_prepare() {
  [[ "$RUNTIME" == swarm || "$RUNTIME" == compose ]] || die "--runtime swarm|compose required"

  # What ships must be what was tested. A tracked file modified locally means
  # the archive below would not match the code under test — and an untracked
  # file a script calls would simply be absent on site.
  [[ -z "$(git -C "$REPO" status --porcelain --untracked-files=no)" ]] \
    || die "working tree is dirty — commit or stash before building a bundle"

  local commit; commit="$(git -C "$REPO" rev-parse --short HEAD)"
  local name="industream-airgap-${commit}-${EDITION}-${RUNTIME}"
  local dest="$OUT/$name"
  rm -rf "$dest"; mkdir -p "$dest/tree" "$dest/images" "$dest/assets" "$dest/os"

  echo "▶ tree (git archive $commit)"
  git -C "$REPO" archive HEAD | tar -x -C "$dest/tree"

  # deploy.sh sources "$BUNDLE_DIR"/.env.* and several of those are not
  # committed (the secrets hook blocks `git add` on them), so the archive alone
  # is not enough.
  echo "▶ resolved bundle env files"
  ( cd "$HERE" && find releases -name '.env.*' -type f -print0 ) \
    | ( cd "$HERE" && xargs -0 -r -I{} cp --parents {} "$dest/tree/unified/" )

  local groups_args=(); [[ -n "$GROUP_SET" ]] && groups_args=(--groups "$GROUP_SET")
  local scope_args; read -ra scope_args <<< "$(deploy_scope_args)"
  echo "▶ resolving the image set"
  local raw_images
  raw_images="$( cd "$HERE" && ./scripts/deploy.sh --runtime "$RUNTIME" --edition "$EDITION" \
      --env "$ENV" --bundle "$BUNDLE" "${scope_args[@]}" "${groups_args[@]}" --list-images )"
  # deploy.sh's progress banner now goes to stderr, so this stdout capture
  # should already be image-only. Kept as defence-in-depth: a real image
  # reference can never contain whitespace (invalid Docker image-ref syntax),
  # so filtering on that is a robust way to drop any stray non-image line
  # without re-deriving the list — resolve_image_list in deploy.sh stays the
  # ONLY source of the images.
  local images
  images="$(grep -v '[[:space:]]' <<<"$raw_images" || true)"
  [[ -n "$images" ]] || die "the image list is empty — check --edition/--groups"

  [[ "$SKIP_IMAGES" == true ]] || save_images "$dest" "$images"
  [[ "$SKIP_ASSETS" == true ]] || harvest_assets "$dest"

  # Recorded for audit alongside the other harvest inputs — only meaningful
  # for compose, whose volume prefix (unlike swarm's fixed ${ENV}-<volume>)
  # depends on whatever --harvest-project resolved to.
  local harvest_project=""
  [[ "$SKIP_ASSETS" == true || "$RUNTIME" != compose ]] || harvest_project="${HARVEST_PROJECT:-$ENV}"

  write_bundle_json "$dest" "$commit" "$images" "$harvest_project"
  ( cd "$dest" && find . -type f ! -name MANIFEST.sha256 -print0 \
      | xargs -0 sha256sum > MANIFEST.sha256 )
  cp "$HERE/scripts/airgap-install.sh" "$dest/install.sh" 2>/dev/null || true
  chmod +x "$dest/install.sh" 2>/dev/null || true

  echo "▶ $dest"
  echo "$dest"
}

# UNCOMPRESSED_BYTES is accumulated by save_images and recorded in bundle.json;
# install.sh sizes its disk preflight from it.
UNCOMPRESSED_BYTES=0

write_bundle_json() {
  local dest="$1" commit="$2" images="$3" harvest_project="$4"
  python3 - "$dest" "$commit" "$EDITION" "$RUNTIME" "$ENV" "$GROUP_SET" "$UNCOMPRESSED_BYTES" "$BUNDLE" "$harvest_project" <<PY
import json, sys, datetime
dest, commit, edition, runtime, env, groups, uncompressed, bundle, harvest_project = sys.argv[1:10]
images = """$images""".split()
json.dump({
    "commit": commit, "edition": edition, "runtime": runtime, "env": env,
    "groups": groups, "bundle": bundle, "harvest_project": harvest_project or None,
    "created": datetime.datetime.now().isoformat(timespec="seconds"),
    "uncompressed_bytes": int(uncompressed), "images": images,
}, open(dest + "/bundle.json", "w"), indent=2)
PY
}

# Split a file that exceeds the cap into numbered parts and drop the original —
# keeping it would double the bundle's size on the transport medium. Parts are
# streamed back with `cat parts | zstd -dc | docker load`, so they are never
# reassembled on the target's disk.
cmd_split() {
  local f="$1" cap="$2"
  [[ "$cap" == 0 ]] && return 0
  local bytes cap_bytes
  bytes="$(stat -c%s "$f")"
  cap_bytes="$(numfmt --from=iec "$cap")"
  (( bytes <= cap_bytes )) && return 0
  split -d -a 2 -b "$cap" "$f" "$f."
  rm -f "$f"
}

# Grouping, like the list itself, comes from the deploy — never from a table.
# render-bundles.sh already shipped a hand-maintained TABLE that silently
# omitted six workers; this must not acquire a second one.
group_names() {
  if [[ -n "$GROUP_SET" ]]; then echo "$GROUP_SET"
  else
    local scope_args; read -ra scope_args <<< "$(deploy_scope_args)"
    ( cd "$HERE" && ./scripts/deploy.sh --runtime "$RUNTIME" --edition "$EDITION" \
        --env "$ENV" --bundle "$BUNDLE" "${scope_args[@]}" --print-groups )
  fi
}

# The images of ONE group, intersected with the full set so that a group whose
# images are all shared with another still yields a coherent tarball.
images_for_group() {
  local group="$1" all="$2"
  local scope_args; read -ra scope_args <<< "$(deploy_scope_args)"
  comm -12 \
    <( cd "$HERE" && ./scripts/deploy.sh --runtime "$RUNTIME" --edition "$EDITION" \
         --env "$ENV" --bundle "$BUNDLE" "${scope_args[@]}" --groups "$group" --list-images | sort -u ) \
    <( sort -u <<<"$all" )
}

# One tarball per group. A single archive would deduplicate shared layers best
# (`docker save` writes each layer once per invocation) but cannot be resumed;
# per-group tarballs cost some duplication of the workers' shared base layers
# and buy file-by-file recovery on a flaky transport.
save_images() {
  local dest="$1" images="$2" group img
  for group in $(group_names); do
    local set; set="$(images_for_group "$group" "$images")"
    [[ -z "$set" ]] && continue
    echo "▶ images: $group"
    for img in $set; do
      if docker image inspect "$img" >/dev/null 2>&1; then
        echo "  local  $img"
      else
        echo "  pull   $img"
        docker pull "$img" || die "cannot pull $img — build the bundle from a connected machine"
      fi
      UNCOMPRESSED_BYTES=$(( UNCOMPRESSED_BYTES + $(docker image inspect -f '{{.Size}}' "$img" 2>/dev/null || echo 0) ))
    done
    # shellcheck disable=SC2086
    docker save $set | zstd -T0 -3 > "$dest/images/$group.tar.zst"
    cmd_split "$dest/images/$group.tar.zst" "$MAX_PART_SIZE"
  done
  ( cd "$dest" && find images -type f -print0 | xargs -0 sha256sum > PARTS.sha256 )
}

# Assets are HARVESTED from a real, connected instance, never rebuilt.
# GRAFANA_HARVEST_TIMEOUT bounds the readiness poll below; overridable so a
# test running under a stub daemon (where the poll can never truly succeed)
# does not have to wait out the real-world default.
: "${GRAFANA_HARVEST_TIMEOUT:=120}"
harvest_assets() {
  local dest="$1"
  # shellcheck disable=SC1091
  set -a; source "$HERE/versions.env"; set +a

  # --- Grafana plugins -------------------------------------------------------
  # base/monitoring.yml installs these with GF_PLUGINS_PREINSTALL_SYNC, which is
  # deliberately boot-blocking: offline, a missing plugin means Grafana does not
  # start at all. GF_PLUGINS_PREINSTALL_SYNC is handled inside grafana-server
  # itself at startup (it delays "HTTP Server Listen" until every listed
  # plugin is installed) — there is no `grafana cli` subcommand that triggers
  # it, so the real server has to actually run. Bind the plugins directory
  # straight onto the host: grafana writes the finished plugin into it
  # directly, so there is nothing left to re-implement or copy out afterwards.
  # This step ALWAYS uses the local daemon — it only ever needs internet
  # access, which the build machine has by definition — so --harvest-from
  # (docker_ctx below) does not apply here, only to the CDN copy further down.
  echo "▶ assets: grafana plugins"
  local preinstall="yesoreyeram-infinity-datasource,marcusolsson-json-datasource,volkovlabs-echarts-panel${GRAFANA_DATABRIDGE_PLUGIN}"
  mkdir -p "$dest/assets/grafana-plugins"
  # Grafana runs as uid 472 in the image, never the host uid, so the mount
  # must be world-writable or the installer fails silently with nothing ever
  # appearing in the directory (no log line either — it just never starts).
  # Tightened back to 755 below, once the container is done writing to it —
  # the bundle output must not ship a world-writable directory.
  chmod 777 "$dest/assets/grafana-plugins"

  local plugin_ids; plugin_ids="$(tr ',' '\n' <<<"$preinstall" | cut -d@ -f1)"
  local cid
  cid="$(docker run -d --rm \
    -e "GF_PLUGINS_PREINSTALL_SYNC=$preinstall" \
    -e GF_PLUGINS_ALLOW_LOADING_UNSIGNED_PLUGINS=industream-databridge-datasource,industream-hubbridge-app \
    -v "$dest/assets/grafana-plugins:/var/lib/grafana/plugins" \
    "grafana/grafana-oss:${GRAFANA_VERSION}")"

  # Poll for every plugin in the sync list rather than trusting a fixed sleep
  # or a log line: Grafana 13 also background-installs its own bundled apps
  # (pyroscope, explore-traces, ...) on the same container, unrelated to our
  # list, so "the container is quiet" is not a valid readiness signal here.
  # `plugin.json` existing is not proof the plugin finished writing (the same
  # race class as the 22MB truncation this task exists to prevent) — requiring
  # the byte total of just our target plugins to also be stable across two
  # consecutive polls catches one still mid-flight, without a fixed extra
  # sleep. Scoped to the target dirs only (not the whole grafana-plugins
  # directory): Grafana's unrelated bundled-app installer keeps writing other
  # plugins in the background for a while after ours are done, which would
  # otherwise stop the total from ever settling.
  local waited=0 id ready size prev_size=-1 target_dirs
  while (( waited < GRAFANA_HARVEST_TIMEOUT )); do
    ready=true
    for id in $plugin_ids; do
      [[ -f "$dest/assets/grafana-plugins/$id/plugin.json" ]] || { ready=false; break; }
    done
    if [[ "$ready" == true ]]; then
      target_dirs=(); for id in $plugin_ids; do target_dirs+=("$dest/assets/grafana-plugins/$id"); done
      size="$(du -sbc "${target_dirs[@]}" 2>/dev/null | tail -1 | cut -f1)"
      [[ "$size" == "$prev_size" ]] && break
      prev_size="$size"
    fi
    sleep 1; waited=$(( waited + 1 ))
  done
  docker stop "$cid" >/dev/null 2>&1 || true

  # Grafana's own background app-updater keeps writing to the same mount after
  # our sync list is done; drop anything that is not one of ours so a plugin
  # stopped mid-download never ships as a silent fragment. Every file in there
  # is owned by the image's uid 472, not the host user, so the removal has to
  # happen inside a container too, not with a host-side rm.
  docker run --rm \
    -e "KEEP=$(tr '\n' ' ' <<<"$plugin_ids")" \
    -v "$dest/assets/grafana-plugins:/plugins" \
    "alpine:${ALPINE_VERSION}" sh -c 'cd /plugins && for d in */; do
        d="${d%/}"
        case " $KEEP " in *" $d "*) ;; *) rm -rf -- "$d" ;; esac
      done'

  [[ -n "$(ls -A "$dest/assets/grafana-plugins")" ]] \
    || die "no Grafana plugin was produced — Grafana will not boot offline"
  chmod 755 "$dest/assets/grafana-plugins"

  # --- CDN packages ----------------------------------------------------------
  # cdn-server (Verdaccio) proxies npmjs and publishes on demand, so offline it
  # stays empty and FlowMaker boxes lose their definitions. Copy the volumes of
  # an instance that has ACTUALLY served them — this is the one asset that
  # genuinely needs a remote, warmed instance, so --harvest-from applies here.
  # A bind mount (`-v host:/container`) resolves on the DAEMON's filesystem,
  # not the client's, so against a real remote --harvest-from it would silently
  # write to the remote host and this script would see nothing. `docker cp`
  # streams through the client instead, so it works the same way against the
  # local daemon or a remote context: create a stopped container with the
  # volume mounted, `cp` its contents out, then discard the container.
  echo "▶ assets: cdn packages"
  local docker_ctx=(); [[ -n "$HARVEST_FROM" ]] && docker_ctx=(--context "$HARVEST_FROM")
  local v vol_prefix
  if [[ "$RUNTIME" == swarm ]]; then
    vol_prefix="${ENV}-"
  else
    # Compose has no fixed volume-naming convention the way the swarm overlays
    # do — --harvest-project must be given explicitly if the live instance's
    # --project differs from $ENV, or the guard below will fire on a genuine
    # miss (wrong volume name), not an actually empty cache.
    vol_prefix="${HARVEST_PROJECT:-$ENV}_"
  fi
  for v in cdn-server-storage cdn-cache-storage; do
    mkdir -p "$dest/assets/cdn-packages/$v"
    local vcid
    vcid="$(docker "${docker_ctx[@]}" create -v "${vol_prefix}${v}:/src:ro" "alpine:${ALPINE_VERSION}" true)"
    docker "${docker_ctx[@]}" cp "$vcid:/src/." "$dest/assets/cdn-packages/$v/" 2>/dev/null || true
    docker "${docker_ctx[@]}" rm "$vcid" >/dev/null 2>&1 || true
  done
  if [[ -n "${AIRGAP_FAKE_EMPTY_CDN:-}" ]] \
     || [[ -z "$(find "$dest/assets/cdn-packages" -type f -print -quit)" ]]; then
    die "CDN cache is empty — harvest from a warmed instance (--harvest-from) or the boxes will have no definition on site"
  fi
}

cmd_verify()    { :; }   # Task 7 — same reasoning as cmd_split above.

# Dispatch. `_split` is exposed so the splitting logic is directly testable.
case "${1:-}" in
  prepare) shift; parse_args "$@"; cmd_prepare ;;
  verify)  shift; cmd_verify "$@" ;;
  _split)  shift; cmd_split "$@" ;;
  *)       die "usage: airgap.sh prepare|verify <args>" ;;
esac
