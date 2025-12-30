require "json"
require "set"
require "log"
require "../cra/indexer"

module CRA
  # Coordinates workspace indexing and query access for LSP handlers.
  class WorkspaceService
    getter database : CRA::Salsa::Database

    def initialize(@database : CRA::Salsa::Database = CRA::Salsa::Database.new)
    end

    def index_workspace(config : CRA::Indexer::Config, &progress : CRA::Indexer::WorkspaceIndexer::ProgressCallback)
      indexer = CRA::Indexer::WorkspaceIndexer.new(@database, config)
      indexer.index!(progress)
    end

    def index_workspace(config : CRA::Indexer::Config)
      indexer = CRA::Indexer::WorkspaceIndexer.new(@database, config)
      indexer.index!
    end

    def workspace_symbols : Hash(CRA::Salsa::FileId, CRA::Salsa::SymbolIndex)
      @database.workspace_symbols
    end

    def symbol_index(file_id : CRA::Salsa::FileId) : CRA::Salsa::SymbolIndex
      @database.symbol_index(file_id)
    end

    def occurrence_index(file_id : CRA::Salsa::FileId) : CRA::Salsa::OccurrenceIndex
      @database.occurrence_index(file_id)
    end

    def require_index(file_id : CRA::Salsa::FileId) : CRA::Salsa::RequireIndex
      @database.require_index(file_id)
    end

    def parsed_document(file_id : CRA::Salsa::FileId) : CRA::Salsa::ParsedDocument
      @database.parsed_document(file_id)
    end
  end
end
