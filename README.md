# cr-analyzer

cr-analyzer is a lightweight Language Server Protocol (LSP) server for the Crystal language. It parses source files with the Crystal parser and builds a semantic index without invoking the full compiler, aiming for fast, editor-friendly feedback.

## Status

Active development. Implemented LSP features today: completion and go-to-definition, plus full-text document sync (didOpen/didChange/didSave). Other LSP features are planned.

## Features

- Workspace scan of project sources, lib, and Crystal stdlib.
- Go to definition for:
  - types (class/module/enum)
  - methods and overloads (arity aware)
  - constructors (new -> initialize/self.new)
  - instance/class/local variables
  - aliases and enum members
- Completion:
  - member methods on . and ::
  - instance/class/local variables
  - type/namespace and enum member completions
  - keyword completions based on context
  - require path suggestions

## Limitations

- No full compiler type checking or macro expansion. Type inference is best-effort based on annotations and simple assignments.
- Macro expansion is limited to built-in macros (getter, setter, property, record) and a small interpreter for user-defined macros.
- References, rename, and diagnostics are not implemented yet (some capabilities are still stubbed).

## Usage

1. Install dependencies:

```
shards install
```

2. Run the server over stdio:

```
crystal run src/bin/cra.cr
```

Or build the binary:

```
shards build
./bin/cr-analyzer
```

3. Configure your editor to launch the command above as an LSP server.

### stdlib scanning

The server uses CRYSTAL_PATH or CRYSTAL_HOME to locate the stdlib. If unset it falls back to /usr/share/crystal/src.

## Development

- Run specs: crystal spec
- Quick client harness: uv run main.py (uses the Python env in pyproject.toml)
- Debug: CRA_DUMP_ROOTS=1 to dump index roots after initial scan

## Docs

- docs/architecture.md
- docs/semantic-index.md
- docs/lsp-server.md

## Contributing

Please open an issue or PR with a clear description and tests when possible.

## Contributors

- Mike Oz - creator and maintainer
