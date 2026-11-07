#!/usr/bin/env python3
"""Persist full-access Codex defaults without overwriting other user settings."""
from pathlib import Path
import re

path = Path.home() / ".codex" / "config.toml"
path.parent.mkdir(parents=True, exist_ok=True)
lines = path.read_text().splitlines(keepends=True) if path.exists() else []
out = []
in_top_level = True
for line in lines:
    if re.match(r"^\s*\[", line):
        in_top_level = False
    if in_top_level and re.match(r"^\s*(approval_policy|sandbox_mode)\s*=", line):
        continue
    out.append(line)
path.write_text('approval_policy = "never"\nsandbox_mode = "danger-full-access"\n' + "".join(out))
print("Codex defaults: approval_policy=never, sandbox_mode=danger-full-access")
