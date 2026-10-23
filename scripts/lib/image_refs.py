"""Resolve compose image references the way `docker stack deploy` will.

Shared by deploy.sh (--list-images, bundle-driven pruning) and
fix-volume-ownership.sh, so every caller agrees on what an image ref becomes.

CLI:
  image_refs.py prune <out-list> <compose-file>...
      Drops, from every file, the services whose image does not resolve (the
      bundle does not provide it). A file that loses services is replaced by a
      hidden pruned copy next to it, so relative paths keep resolving. Writes
      the resulting file list to <out-list>, one per line, and exits 2 when a
      platform-base service is the one missing.
"""
import os
import re
import sys

import yaml

PLAIN = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}")
DEFAULTED = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*):-([^${}]*)\}")

# Without these the platform does not work at all: a bundle missing one is
# refused rather than deployed without it.
PLATFORM_BASE = {
    "industream-hub-backend", "industream-hub-frontend",
    "flowmaker-scheduler", "flowmaker-confighub", "flowmaker-logging", "flowmaker-frontend",
    "datacatalog-api", "datacatalog-ui",
    "cdn-server", "cdn-cache",
}

PRUNED_SUFFIX = ".pruned.yml"


def expand(value):
    """Expand ${VAR} and ${VAR:-default} (nested) from the process env.

    os.path.expandvars stops at the first "}" of ${A:-x${B}} and has no
    defaults, so plain vars then innermost defaults are resolved until stable.
    """
    if value is None:
        return ""
    ref = str(value)
    while True:
        resolved = PLAIN.sub(lambda m: os.environ.get(m.group(1), m.group(0)), ref)
        resolved = DEFAULTED.sub(lambda m: os.environ.get(m.group(1)) or m.group(2), resolved)
        if resolved == ref:
            return os.path.expandvars(ref)
        ref = resolved


def is_resolved(ref):
    return bool(ref) and "$" not in ref


def load_services(path):
    try:
        doc = yaml.safe_load(open(path)) or {}
    except (OSError, yaml.YAMLError):
        return {}, {}
    return doc, doc.get("services") or {}


def unprovided_services(files):
    """Services whose final image (last file wins) does not resolve."""
    images = {}
    for path in files:
        _, services = load_services(path)
        for name, spec in services.items():
            if isinstance(spec, dict) and "image" in spec:
                images[name] = expand(spec["image"])
    return sorted(name for name, ref in images.items() if not is_resolved(ref))


def pruned_path(path):
    head, tail = os.path.split(path)
    return os.path.join(head, "." + tail[: -len(".yml")] + PRUNED_SUFFIX)


def prune(out_list, files):
    dropped = unprovided_services(files)
    blocking = [name for name in dropped if name in PLATFORM_BASE]
    if blocking:
        print("✗ the bundle provides no image for platform service(s): " + ", ".join(blocking), file=sys.stderr)
        return 2

    kept_files = []
    for path in files:
        doc, services = load_services(path)
        if not set(services) & set(dropped):
            kept_files.append(path)
            continue

        doc["services"] = {name: spec for name, spec in services.items() if name not in dropped}
        target = pruned_path(path)
        with open(target, "w") as handle:
            yaml.safe_dump(doc, handle, sort_keys=False)
        kept_files.append(target)

    if dropped:
        print("  ⚠ not in the bundle, not deployed: " + " ".join(dropped), file=sys.stderr)
    with open(out_list, "w") as handle:
        handle.write("\n".join(kept_files) + "\n")
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 3 or sys.argv[1] != "prune":
        sys.exit("usage: image_refs.py prune <out-list> <compose-file>...")
    sys.exit(prune(sys.argv[2], sys.argv[3:]))
