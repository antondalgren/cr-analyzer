# AGENTS

This file is for contributors and automation agents working on this repo.

## Project summary

cr-analyzer is a lightweight LSP server for Crystal. It parses files with Crystal::Parser and builds a SemanticIndex for completions and go-to-definition without invoking the full compiler.

## Setup

- Requires Crystal >= 1.18.2 and shards.
- Install deps: shards install
- Run: crystal run src/bin/cra.cr
- Build: shards build (binary at bin/cr-analyzer)
- Tests: crystal spec
- Manual client: uv run main.py (uses the Python env in pyproject.toml)

## Repo layout

- src/cr-analyzer.cr: JSON-RPC server and request handlers.
- src/bin/cra.cr: server entry point.
- src/cra/workspace.cr: workspace scan, reindex, completion and definition routing.
- src/cra/workspace/: NodeFinder, document model, completion providers.
- src/cra/semantic/: SemanticIndex, indexing passes, TypeRef.
- src/cra/analysis/: macro expansion helpers (MacroExpander/MacroInterpreter).
- src/cra/types.cr: LSP types and protocol classes.
- spec/: specs.

## Data flow

- Initialize -> Workspace.scan -> parse and index all files.
- didOpen/didChange/didSave -> WorkspaceDocument update -> parse -> reindex file + dependent types.
- completion -> NodeFinder -> CompletionContext -> providers.
- definition -> NodeFinder -> SemanticIndex.find_definitions.

## Semantic Index notes

- Two passes: SkeletonIndexer (type shells) and SemanticIndexer (methods/includes/enums/aliases).
- TypeRef is lightweight: name + generic args + union types. Inference is best-effort (annotations, Foo.new, Array/Hash literals with of).
- Macro expansion is limited; expanded code is indexed under crystal-macro: URIs.

## Environment

- CRYSTAL_PATH or CRYSTAL_HOME controls stdlib scan; fallback is /usr/share/crystal/src.
- CRA_DUMP_ROOTS=1 logs index roots on scan.

## LSP status

- Implemented: completion, definition, full-text sync.
- Not implemented yet: references, rename, diagnostics, workspace symbols, type definition, implementation (even if currently advertised in capabilities). Keep docs and ServerCapabilities in sync when you add these.
