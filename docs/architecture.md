# Architecture

This document describes the major runtime pieces and the request flow.

## Components

- `CRA::JsonRPC::Server`: stdio transport, reads/writes LSP JSON-RPC.
- `CRA::JsonRPC::Processor`: dispatches requests; owns a `Workspace`.
- `CRA::Workspace`: manages documents, indexing, completions, definitions, references, diagnostics.
- `CRA::WorkspaceDocument`: stores text, parsed AST, diagnostics, and NodeFinder context.
- `CRA::Psi::SemanticIndex`: semantic database for types, methods, vars, aliases, enums; call graph.
- Completion providers: `SemanticIndex`, `KeywordCompletionProvider`, `RequirePathCompletionProvider`.
- `DocumentSymbolsIndex`: AST visitor for document/workspace symbols.

## Request flow

1. Initialize -> Workspace.scan -> parse and index project, lib, and stdlib files.
2. didOpen/didChange/didSave -> update document text -> parse -> Workspace.reindex_file.
3. completion -> NodeFinder -> CompletionContext -> providers -> merged items.
4. definition/declaration/implementation/typeDefinition -> NodeFinder -> SemanticIndex.find_definitions.
5. references -> NodeFinder -> Workspace/SemanticIndex references.
6. call hierarchy -> SemanticIndex call graph.
7. diagnostics -> WorkspaceDocument parse + facet lints -> publish/pull.

## Indexing and updates

- Full text sync (TextDocumentSyncKind::Full).
- Each change parses the full document with Crystal::Parser.
- Reindexing also reindexes dependent types based on include/extend and superclass relationships.
- stdlib lookup uses CRYSTAL_PATH or CRYSTAL_HOME, with /usr/share/crystal/src as fallback.
