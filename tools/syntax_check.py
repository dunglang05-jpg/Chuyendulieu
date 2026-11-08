"""Syntax-only check (tree-sitter). Not a compiler: no types, imports or API checks."""
import sys, pathlib
from tree_sitter import Language, Parser
import tree_sitter_kotlin, tree_sitter_swift, tree_sitter_dart_orchard
LANGS = {".kt": Language(tree_sitter_kotlin.language()), ".swift": Language(tree_sitter_swift.language()),
         ".dart": Language(tree_sitter_dart_orchard.language())}
bad = 0; total = 0
for root in sys.argv[1:]:
    for f in sorted(pathlib.Path(root).rglob("*")):
        lang = LANGS.get(f.suffix)
        if not lang or ".dart_tool" in f.parts: continue
        total += 1
        tree = Parser(lang).parse(f.read_bytes())
        errs = []
        def walk(n):
            if n.type == "ERROR" or n.is_missing:
                errs.append((n.start_point[0] + 1, n.start_point[1] + 1, n.type, f.read_bytes()[n.start_byte:n.end_byte][:60]))
                return
            for ch in n.children: walk(ch)
        walk(tree.root_node)
        if errs:
            bad += 1
            print(f"{f}: {len(errs)} issue(s)")
            for e in errs[:6]: print("   line %d col %d %s %r" % e)
print(f"checked {total} files, {bad} with syntax issues")
