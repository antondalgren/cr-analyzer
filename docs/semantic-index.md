# Semantic Index

SemanticIndex is the core semantic database used for completion and definition.

## Data model

- PsiElement base class with file and location.
- Types: Module, Class, Enum, Method, InstanceVar, ClassVar, LocalVar, Alias, EnumMember.
- TypeRef: lightweight type handle with a name, generic args, and union variants.

## Indexing passes

- SkeletonIndexer: builds type shells and records type variables and superclasses.
- SemanticIndexer: attaches methods, includes, enum members, and aliases.
- Macro pre-expansion: expands supported macros into virtual files for indexing.

## Type hints

Type inference is intentionally light. The indexer extracts TypeRef from:

- explicit type annotations
- simple assignments when the RHS is a Foo.new call
- array or hash literals with an explicit of type
- casts, metaclasses, and union/generic type syntax

## Resolution

find_definitions resolves:

- types and namespaces (Path, Generic)
- enum members
- aliases
- methods with arity filtering, including inherited methods (including class vs instance, includes, superclasses)
- locals, instance vars, class vars
- constructors (new -> initialize/self.new)
- call hierarchy edges (outgoing/incoming) via resolved calls
- references for types/aliases across files (path matching)

## Dependencies

Include/extend and superclass edges are tracked. When a file changes, dependent types and their files are reindexed.

## Macro expansion

Supported macros:

- built-in: getter, setter, property, record
- user-defined: interpreted via a small MacroInterpreter

Expanded nodes are indexed under crystal-macro: virtual URIs.
