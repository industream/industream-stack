"""Resolve compose image references the way `docker stack deploy` will.

Shared by deploy.sh (--list-images) and fix-volume-ownership.sh, so every
caller agrees on what an image ref becomes.
"""
import os
import re

PLAIN = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}")
DEFAULTED = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*):-([^${}]*)\}")


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
