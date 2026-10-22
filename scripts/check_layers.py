#!/usr/bin/env python3
"""The layering check (VMC-077r): no file depends on a context above its own.

Every module lives in a context, a directory under `lib/valimc` (its facade, if
any, is the file of the same name beside it). The contexts are ranked; a file
may depend on its own rank and the ranks below it, never above:

    Data < Protocol, Text < Physics, Living, Blocks, Menus, Txn < Entity
         < World, Player, Admin, Storage, Worldgen < Session, Commands < Net

A dependency is any `mix xref` edge (compile, export or runtime). The root
module (`lib/valimc.ex`) and the NIF module rank with Data; the application,
which starts everything, is above every context.

    python3 scripts/check_layers.py [--json XREF_JSON] [--report]

`--report` prints the edge counts between contexts and the largest dependency
cycle instead of failing on violations. `ALLOWED` lists the known upward
edges, each with the change that removes it.
"""
import collections, json, pathlib, subprocess, sys, tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
RANKS = [
    ["data"],
    ["protocol", "text"],
    ["physics", "living", "blocks", "menus", "txn"],
    ["entity"],
    ["world", "player", "admin", "storage", "worldgen"],
    ["session", "commands"],
    ["net"],
]
RANK = {context: rank for rank, contexts in enumerate(RANKS) for context in contexts}
BASE = {"lib/valimc.ex", "lib/valimc/native.ex"}
# Known upward edges, each with the change that removes it. The check fails on
# any other violation and on an entry that no longer occurs.
ALLOWED = {
    # Block behaviours read their level's build height from the owner's
    # dimension context; passing the level to the callbacks removes it.
    ("lib/valimc/blocks/nether_portal.ex", "lib/valimc/world/dimension.ex"): "level height",
}
TOP = {"lib/valimc/application.ex"}


def context(path):
    """The context of a file, `base`, `top`, or None outside lib/valimc."""
    if path in BASE:
        return "base"
    if path in TOP:
        return "top"
    parts = pathlib.PurePosixPath(path).parts
    if parts[:2] != ("lib", "valimc") or len(parts) < 3:
        return None
    name = parts[2][:-3] if len(parts) == 3 else parts[2]
    return name if name in RANK else f"?{name}"


def rank(name):
    return {"base": 0, "top": len(RANKS)}.get(name, RANK.get(name))


def graph(xref_json=None):
    if xref_json is None:
        with tempfile.TemporaryDirectory(prefix="valimc-xref-") as scratch:
            out = pathlib.Path(scratch) / "xref.json"
            subprocess.run(["mix", "xref", "graph", "--format", "json", "--output", str(out)],
                           cwd=ROOT, check=True, capture_output=True)
            return json.loads(out.read_text())
    return json.loads(pathlib.Path(xref_json).read_text())


def largest_cycle(edges):
    """The size of the largest strongly connected set of files (Tarjan, iterative)."""
    index, low, on, stack, best, counter = {}, {}, set(), [], 0, [0]
    for start in edges:
        if start in index:
            continue
        work = [(start, iter(edges.get(start, ())))]
        index[start] = low[start] = counter[0]; counter[0] += 1
        stack.append(start); on.add(start)
        while work:
            node, children = work[-1]
            for child in children:
                if child not in index:
                    index[child] = low[child] = counter[0]; counter[0] += 1
                    stack.append(child); on.add(child)
                    work.append((child, iter(edges.get(child, ()))))
                    break
                if child in on:
                    low[node] = min(low[node], index[child])
            else:
                work.pop()
                if work:
                    low[work[-1][0]] = min(low[work[-1][0]], low[node])
                if low[node] == index[node]:
                    size = 0
                    while True:
                        member = stack.pop(); on.discard(member); size += 1
                        if member == node:
                            break
                    best = max(best, size)
    return best


def check(edges):
    """Violations as (from file, to file), unknown contexts, and counts between contexts."""
    violations, unknown, counts = [], set(), collections.Counter()
    for source, targets in edges.items():
        a = context(source)
        if a is None:
            continue
        for target in targets:
            b = context(target)
            if b is None or a == b:
                continue
            for name in (a, b):
                if name.startswith("?"):
                    unknown.add(name[1:])
            counts[(a, b)] += 1
            if not (a.startswith("?") or b.startswith("?")) and rank(a) < rank(b):
                violations.append((source, target))
    return violations, unknown, counts


def main():
    args = sys.argv[1:]
    xref_json = args[args.index("--json") + 1] if "--json" in args else None
    edges = graph(xref_json)
    violations, unknown, counts = check(edges)
    if "--report" in args:
        for (a, b), n in sorted(counts.items(), key=lambda item: (-item[1], item[0])):
            mark = " (violation)" if not (a.startswith("?") or b.startswith("?")) and rank(a) < rank(b) else ""
            print(f"{a} -> {b}: {n}{mark}")
        print(f"files: {len(edges)}; largest cycle: {largest_cycle(edges)} files; "
              f"violations: {len(violations)}")
        return
    problems = [f"{a} -> {b}: {context(a)} may not depend on {context(b)}"
                for a, b in sorted(violations) if (a, b) not in ALLOWED]
    problems += [f"{a} -> {b}: allowed in scripts/check_layers.py but no longer a dependency"
                 for a, b in sorted(set(ALLOWED) - set(violations))]
    problems += [f"lib/valimc/{name}: not a ranked context (scripts/check_layers.py)" for name in sorted(unknown)]
    if problems:
        raise SystemExit("LAYERING CHECK FAILED\n" + "\n".join(problems))
    print(f"PASS: {len(edges)} files depend only on their own or lower layers "
          f"({len(ALLOWED)} known exception{'' if len(ALLOWED) == 1 else 's'})")


if __name__ == "__main__":
    main()
