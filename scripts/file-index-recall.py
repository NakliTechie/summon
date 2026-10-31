#!/usr/bin/env python3
"""File-index recall against ripgrep ground truth (the recall half of the Benchmark chunk).

For each query, the truth is every regular file under ROOT whose name contains
the expected text (case-insensitive), as `rg --files` lists them. Two truths:

  all       rg --files --no-ignore --hidden: every file on disk
  in scope  rg --files --hidden: .gitignore/.ignore honoured, as the index does

Recall = truth files the index returned / truth files. Excluded folder names
(`FileIndexExclusions.standard`) are dropped from both truths, so a miss in the
in-scope column is a defect, not a listed exclusion. A typo query is scored
against the truth of the word it means ("mian" against "main").

With `--fff <bench/fff-harness binary>`, fff (the recall reference) is scored on
the same truths. Not a latency benchmark: it runs on any build and loaded machine.

  scripts/file-index-recall.py [--fff <fff-harness>] <summon-cli> <root> [query[=expected] ...]

The CLI reads the index from its container (`SUMMON_CONTAINER_DIR` overrides).
"""

from __future__ import annotations

import os
import subprocess
import sys

DEFAULT_QUERIES = ["main", "readme", "package.json", "invoice", "config", "mian=main"]
# FileIndexExclusions.standard names; keep in step with FileCrawler.swift.
EXCLUDED_NAMES = {".git", ".DS_Store", ".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100", "Cache_Data"}


def regular_files(paths: list[str]) -> set[str]:
    out = set()
    for path in paths:
        if EXCLUDED_NAMES.intersection(path.split("/")):
            continue
        try:
            if os.path.isfile(path) and not os.path.islink(path):
                out.add(path)
        except OSError:
            continue
    return out


def rg_files(root: str, respect_ignores: bool) -> list[str]:
    args = ["rg", "--files", "--hidden", "--no-messages"]
    if not respect_ignores:
        args.append("--no-ignore")
    # rg exits 2 on unreadable folders but still lists the rest.
    run = subprocess.run(args + [root], capture_output=True, text=True)
    return [line for line in run.stdout.splitlines() if line]


def index_results(cli: str, root: str, query: str) -> set[str]:
    run = subprocess.run(
        [cli, "files", "search", "--limit", "10000000", f"{query} in:{root}"],
        capture_output=True, text=True,
    )
    paths = []
    for line in run.stdout.splitlines():
        number, _, path = line.partition(". ")
        if number.isdigit() and path:
            paths.append(path)
    return regular_files(paths)


def fff_results(harness: str, root: str, queries: list[str]) -> dict[str, set[str]]:
    run = subprocess.run([harness, root, *queries], capture_output=True, text=True, check=True)
    results: dict[str, list[str]] = {}
    current = None
    for line in run.stdout.splitlines():
        if line.startswith("## "):
            current = line[3:].rsplit(" ", 2)[0]
            results[current] = []
        elif current is not None and line:
            results[current].append(line)
    return {query: regular_files(paths) for query, paths in results.items()}


def recall(found: set[str], truth: set[str]) -> tuple[int, float]:
    hits = len(found & truth)
    return hits, hits / len(truth) if truth else 1.0


def main() -> int:
    argv = sys.argv[1:]
    harness = None
    if argv[:1] == ["--fff"] and len(argv) > 1:
        harness, argv = argv[1], argv[2:]
    if len(argv) < 2:
        print(__doc__)
        return 2
    cli, root = argv[0], os.path.realpath(os.path.expanduser(argv[1]))
    queries = argv[2:] or DEFAULT_QUERIES
    fff = fff_results(harness, root, [q.partition("=")[0] for q in queries]) if harness else {}
    every = rg_files(root, respect_ignores=False)
    scoped = rg_files(root, respect_ignores=True)
    print(f"root {root}: rg lists {len(every)} files, {len(scoped)} with ignore files honoured")
    header = "query | truth all | found | recall all | truth in scope | found | recall in scope | index files returned"
    print(header + (" | fff in scope | fff recall in scope | fff files returned" if harness else ""))
    worst = 1.0
    for spec in queries:
        query, _, expected = spec.partition("=")
        needle = (expected or query).lower()
        truth_all = regular_files([p for p in every if needle in os.path.basename(p).lower()])
        truth_scope = regular_files([p for p in scoped if needle in os.path.basename(p).lower()])
        found = index_results(cli, root, query)
        hit_all, recall_all = recall(found, truth_all)
        hit_scope, recall_scope = recall(found, truth_scope)
        worst = min(worst, recall_scope)
        row = (f"{spec} | {len(truth_all)} | {hit_all} | {recall_all:.3f} | "
               f"{len(truth_scope)} | {hit_scope} | {recall_scope:.3f} | {len(found)}")
        if harness:
            fff_found = fff.get(query, set())
            fff_hits, fff_recall = recall(fff_found, truth_scope)
            row += f" | {fff_hits} | {fff_recall:.3f} | {len(fff_found)}"
        print(row)
        for path in sorted(truth_scope - found)[:5]:
            print(f"  missed in scope: {path}")
    print(f"lowest in-scope recall: {worst:.3f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
