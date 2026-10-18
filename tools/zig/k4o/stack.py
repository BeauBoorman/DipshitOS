"""Conservative whole-image stack bound for the pinned C2 guest path.

Charge EVERY emitted function once, not just a sampled execution path, then
charge each data-recursive SCC eight extra times. The iterative guest preflight
bounds template blocks, condition-tree complexity and JSON container depth at
eight. JSON also bounds the Markdown orphan-list recursion and value equality.
Allocator/writer/reader callbacks cannot re-enter the engine. Those callbacks
are charged by the whole-image sum, including the SDK's unused typed vtable.

Panic transitions are terminal: the allocation-free native diagnostic handler
does not format, recurse into engine/Io writers, or use a hosted debug backend.
Its checked console counters advance only by confirmed in-range byte counts.
Thus safety-panic backedges are not input-recursive SCCs. New cycles or stack
adjustments fail closed; compiler/source pins are checked separately.
"""
import re


def bound(assembly, frames):
    graph = {name: set() for name in frames}
    name = None
    for line in assembly.splitlines():
        match = re.search(r"\.type\s+(.+),@function", line)
        if match:
            name = match[1]
        match = re.fullmatch(r"\s*b(?:l)?\s+(.+)", line)
        if match and name in graph and match[1] in graph:
            target = match[1]
            if "debug.FullPanic" in target or "debug.panicExtra" in target:
                continue
            graph[name].add(target)
    indexes, lows, pending, done, groups = {}, {}, [], set(), []

    def visit(v):
        indexes[v] = lows[v] = len(indexes)
        pending.append(v)
        for w in graph[v]:
            if w not in indexes:
                visit(w)
                lows[v] = min(lows[v], lows[w])
            elif w not in done:
                lows[v] = min(lows[v], indexes[w])
        if lows[v] == indexes[v]:
            group = []
            while True:
                w = pending.pop()
                done.add(w)
                group.append(w)
                if w == v:
                    break
            if len(group) > 1 or v in graph[v]:
                groups.append(sorted(group))

    for v in graph:
        if v not in indexes:
            visit(v)
    allowed = {
        ".Lengine.valueEqDepth", ".Lengine.Interp.evalCond", ".Lengine.Interp.evalNodes",
        ".Lfilters.emitListLevel", ".Lparse.Parser.parseSeq", ".Lparse.Parser.parseIfChain",
        ".Lparse.Scanner.parseNot", ".Lparse.Scanner.parseAnd", ".Lparse.Scanner.parseOr",
    }
    recursive = {v for group in groups for v in group}
    if any(v not in allowed and not (v.startswith(".Ljson.Stringify.write__anon_")
                                     or v.startswith(".Ljson.Stringify.write__func_")) for v in recursive):
        raise ValueError("UnreviewedStackRecursion: " + str(groups))
    total = sum(frames.values()) + 8 * sum(frames[v] for v in recursive)
    if total > 128 * 1024:
        raise ValueError(f"StackBudget: conservative bound {total} exceeds 131072")
    return {"whole_image_frames": sum(frames.values()), "recursive_groups": groups,
            "maximum_recursive_activations": 9, "bound_bytes": total}
