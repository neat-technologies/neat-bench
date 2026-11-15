#!/usr/bin/env python3
"""Redact machine-specific strings from run artifacts before they are committed.

Run artifacts are the raw record of what each trial did, so this touches as little as it can:
only strings that identify the bench box on a private network, or name unrelated tools that
happened to be installed on it and showed up in an agent's `ls` output. Each rule replaces the
match with a fixed placeholder of a different shape, so a redacted file is easy to tell apart
from the original and the pass is safe to run twice.

Usage: scripts/redact-runs.py runs/<run-dir> [runs/<run-dir> ...]
Prints one line per rule with the number of replacements made.
"""
import pathlib
import re
import sys

RULES = [
    # The box's address on a private mesh network.
    ("box-ip", re.compile(r"\b100\.113\.183\.95\b"), "<bench-box-ip>"),
    # Unrelated tools installed on the box, seen only in directory listings.
    # Matched as a plain substring: in a JSON transcript the name follows an escaped newline
    # ("\\ngraphify"), where a word boundary does not hold.
    ("unrelated-tool", re.compile(r"graphify(?:-mcp)?", re.IGNORECASE), "<unrelated-tool>"),
]

TEXT_SUFFIXES = {".json", ".out", ".log", ".txt", ".md", ".patch", ".diff"}


def main(dirs):
    counts = {name: 0 for name, _, _ in RULES}
    files = 0
    for d in dirs:
        for p in sorted(pathlib.Path(d).rglob("*")):
            if not p.is_file() or p.suffix not in TEXT_SUFFIXES:
                continue
            text = p.read_text(encoding="utf-8", errors="surrogateescape")
            out = text
            for name, rx, repl in RULES:
                out, n = rx.subn(repl, out)
                counts[name] += n
            if out != text:
                p.write_text(out, encoding="utf-8", errors="surrogateescape")
                files += 1
    for name, n in counts.items():
        print(f"{name}: {n} replacement(s)")
    print(f"files changed: {files}")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    main(sys.argv[1:])
