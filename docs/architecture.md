# Architecture

This document describes the major runtime pieces and the request flow.

## Components

- CRA::JsonRPC::Server: stdio transport, reads/writes LSP JSON-RPC.
- CRA::JsonRPC::Processor: request handlers; owns a Workspace.
- CRA::Workspace: manages documents, indexing, completions, and definitions.
- CRA::WorkspaceDocument: stores text and parsed AST, plus NodeFinder context.
- CRA::Psi::SemanticIndex: semantic database for types, methods, vars, aliases, enums.
- Completion providers: SemanticIndex, KeywordCompletionProvider, RequirePathCompletionProvider.
- DocumentSymbolsIndex: AST visitor for document symbols (available but not advertised yet).

## Request flow

1. Initialize -> Workspace.scan -> parse and index project, lib, and stdlib files.
2. didOpen/didChange/didSave -> update document text -> parse -> Workspace.reindex_file.
3. completion -> NodeFinder -> CompletionContext -> providers -> merged items.
4. definition -> NodeFinder -> SemanticIndex.find_definitions -> locations.

## Indexing and updates

- Full text sync (TextDocumentSyncKind::Full).
- Each change parses the full document with Crystal::Parser.
- Reindexing also reindexes dependent types based on include/extend and superclass relationships.
- stdlib lookup uses CRYSTAL_PATH or CRYSTAL_HOME, with /usr/share/crystal/src as fallback.
