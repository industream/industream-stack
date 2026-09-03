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
MAX_PART_SIZE="3800M" SKIP_IMAGES=false SKIP_ASSETS=false
# --bundle picks releases/bundle-platform-<ver>/ — same meaning as deploy.sh's
# --bundle. Defaulted here (rather than left to deploy.sh's own auto-select) so
# a repo with more than one release bundle checked out still resolves without
# extra flags.
BUNDLE="1.0.1"

die() { echo "✗ $*" >&2; exit 1; }

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
      --harvest-from)   HARVEST_FROM="$2"; shift 2 ;;
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
  # deploy.sh requires --stack (swarm) / --project (compose) unconditionally —
  # even for --list-images, which is checked before the flag is otherwise used.
  # airgap.sh never deploys, so the value only has to satisfy that guard.
  local scope_args=()
  if [[ "$RUNTIME" == swarm ]]; then scope_args=(--stack airgap-list-images)
  else scope_args=(--project airgap-list-images); fi
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

  write_bundle_json "$dest" "$commit" "$images"
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
  local dest="$1" commit="$2" images="$3"
  python3 - "$dest" "$commit" "$EDITION" "$RUNTIME" "$ENV" "$GROUP_SET" "$UNCOMPRESSED_BYTES" "$BUNDLE" <<PY
import json, sys, datetime
dest, commit, edition, runtime, env, groups, uncompressed, bundle = sys.argv[1:9]
images = """$images""".split()
json.dump({
    "commit": commit, "edition": edition, "runtime": runtime, "env": env,
    "groups": groups, "bundle": bundle,
    "created": datetime.datetime.now().isoformat(timespec="seconds"),
    "uncompressed_bytes": int(uncompressed), "images": images,
}, open(dest + "/bundle.json", "w"), indent=2)
PY
}

save_images()   { :; }   # Task 5
harvest_assets(){ :; }   # Task 6
cmd_split()     { :; }   # Task 5 — stubbed here so the dispatch below routes to a
                         # defined function (shellcheck and any reviewer flag a
                         # dispatch to a function no file defines).
cmd_verify()    { :; }   # Task 7 — same reasoning as cmd_split above.

# Dispatch. `_split` is exposed so the splitting logic is directly testable.
case "${1:-}" in
  prepare) shift; parse_args "$@"; cmd_prepare ;;
  verify)  shift; cmd_verify "$@" ;;
  _split)  shift; cmd_split "$@" ;;
  *)       die "usage: airgap.sh prepare|verify <args>" ;;
esac
