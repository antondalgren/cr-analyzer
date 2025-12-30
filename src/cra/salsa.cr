require "json"
require "file_utils"
require "digest/sha1"
require "set"
require "./semantic_worker"

module CRA
  module Salsa
    # Represents a unique file inside the workspace.
    struct FileId
      getter path : String

      def initialize(@path : String)
      end

      def hash(hasher)
        @path.hash(hasher)
      end

      def ==(other : FileId)
        @path == other.path
      end

      def to_s(io : IO) : Nil
        io << "FileId(" << @path << ')'
      end
    end

    # Snapshot of a file at a particular revision.
    struct FileSnapshot
      getter text : String
      getter version : Int64

      def initialize(@text : String, @version : Int64)
      end
    end

    # Simplified representation of parsed data.
    class ParsedDocument
      getter tokens : Array(String)
      getter errors : Array(String)

      def initialize(@tokens : Array(String), @errors : Array(String))
      end

      def empty?
        @tokens.empty? && @errors.empty?
      end
    end

    # Symbol index extracted from a file.
    class SymbolIndex
      include JSON::Serializable

      getter symbols : Array(Semantic::SymbolInfo)

      def initialize(@symbols : Array(Semantic::SymbolInfo))
      end

      def empty?
        @symbols.empty?
      end
    end

    # Occurrence index extracted from a file.
    class OccurrenceIndex
      include JSON::Serializable

      getter occurrences : Array(Semantic::Occurrence)

      def initialize(@occurrences : Array(Semantic::Occurrence))
      end

      def empty?
        @occurrences.empty?
      end
    end

    # Require edges for a file.
    class RequireIndex
      include JSON::Serializable

      getter requires : Array(Semantic::RequireEdge)

      def initialize(@requires : Array(Semantic::RequireEdge))
      end

      def empty?
        @requires.empty?
      end
    end

    # Payload stored on disk for persisted symbol indexes.
    private struct PersistedSymbolPayload
      include JSON::Serializable

      getter version : Int64
      getter symbols : Array(Semantic::SymbolInfo)
      getter occurrences : Array(Semantic::Occurrence)
      getter requires : Array(Semantic::RequireEdge)

      def initialize(
        @version : Int64,
        @symbols : Array(Semantic::SymbolInfo),
        @occurrences : Array(Semantic::Occurrence) = [] of Semantic::Occurrence,
        @requires : Array(Semantic::RequireEdge) = [] of Semantic::RequireEdge,
      )
      end
    end

    # Raised when a request is made for a file that does not exist in the database.
    class MissingInputError < Exception
      getter file_id : FileId

      def initialize(@file_id : FileId)
        super "Missing input for #{file_id}"
      end
    end

    # Configuration for the database and disk-backed caches.
    struct Config
      getter root_path : String
      getter index_directory : String
      getter persist_symbols : Bool
      getter max_in_memory_symbols : Int32

      def initialize(root_path : String = Dir.current,

                     index_directory : String = ".cr-index",

                     persist_symbols : Bool = true,
                     max_in_memory_symbols : Int32 = 64)
        @root_path = File.expand_path(root_path)
        @index_directory = File.expand_path(index_directory, @root_path)
        @persist_symbols = persist_symbols
        @max_in_memory_symbols = max_in_memory_symbols
      end
    end

    alias QueryKey = FileId | Nil

    struct QueryId
      getter name : Symbol
      getter key : QueryKey

      def initialize(@name : Symbol, @key : QueryKey)
      end

      def hash(hasher)
        @name.hash(hasher)
        @key.hash(hasher)
      end

      def ==(other : QueryId)
        @name == other.name && @key == other.key
      end

      def to_s(io : IO) : Nil
        io << @name << '(' << @key << ')'
      end
    end

    struct Dependency
      getter id : QueryId
      getter changed_at : Int64

      def initialize(@id : QueryId, @changed_at : Int64)
      end
    end

    class QueryEntry(T)
      property value : T
      property verified_at : Int64
      property changed_at : Int64
      property dependencies : Array(Dependency)

      def initialize(@value : T, @verified_at : Int64, @changed_at : Int64, @dependencies : Array(Dependency))
      end
    end

    # Central component responsible for caching query results and providing metrics.
    class Database
      getter config : Config
      getter semantic_worker : Semantic::Worker?
      getter parse_calls : Int64
      getter symbol_index_calls : Int64
      getter workspace_symbols_calls : Int64

      @file_inputs : Hash(FileId, FileSnapshot)
      @input_changed_at : Hash(FileId, Int64)
      @input_set_changed_at : Int64
      @current_revision : Int64
      @parsed_cache : Hash(FileId, QueryEntry(ParsedDocument))
      @symbol_cache : Hash(FileId, QueryEntry(SymbolIndex))
      @occurrence_cache : Hash(FileId, QueryEntry(OccurrenceIndex))
      @require_cache : Hash(FileId, QueryEntry(RequireIndex))
      @symbol_cache_order : Array(FileId)
      @workspace_symbols_cache : QueryEntry(Hash(FileId, SymbolIndex))?
      @persisted_versions : Hash(FileId, Int64)
      @active_query_ids : Set(QueryId)
      @dependency_stack : Array(Array(Dependency))
      @parse_calls : Int64
      @symbol_index_calls : Int64
      @workspace_symbols_calls : Int64

      def initialize(config : Config = Config.new, semantic_worker : Semantic::Worker? = Semantic::Worker.new)
        @config = config
        @semantic_worker = semantic_worker
        @file_inputs = {} of FileId => FileSnapshot
        @input_changed_at = {} of FileId => Int64
        @input_set_changed_at = 0_i64
        @current_revision = 0_i64
        @parsed_cache = {} of FileId => QueryEntry(ParsedDocument)
        @symbol_cache = {} of FileId => QueryEntry(SymbolIndex)
        @occurrence_cache = {} of FileId => QueryEntry(OccurrenceIndex)
        @require_cache = {} of FileId => QueryEntry(RequireIndex)
        @symbol_cache_order = [] of FileId
        @workspace_symbols_cache = nil
        @persisted_versions = {} of FileId => Int64
        @active_query_ids = Set(QueryId).new
        @dependency_stack = [] of Array(Dependency)

        @parse_calls = 0_i64
        @symbol_index_calls = 0_i64
        @workspace_symbols_calls = 0_i64

        ensure_index_directory
      end

      # Writes file content and invalidates dependent caches.
      def write_file(file_id : FileId, text : String, version : Int64) : FileSnapshot
        existing_version = persisted_version(file_id)
        unchanged = existing_version && existing_version == version

        snapshot = FileSnapshot.new(text, version)
        @file_inputs[file_id] = snapshot

        if unchanged
          # Maintain stable revision for unchanged files so caches stay valid.
          @input_changed_at[file_id] ||= @current_revision
          return snapshot
        end

        bump_revision
        new_file = !@input_changed_at.has_key?(file_id)
        @input_changed_at[file_id] = @current_revision
        @input_set_changed_at = @current_revision if new_file
        @parsed_cache.delete(file_id)
        if @symbol_cache.delete(file_id)
          @symbol_cache_order.delete(file_id)
        end
        @occurrence_cache.delete(file_id)
        @require_cache.delete(file_id)
        @workspace_symbols_cache = nil
        snapshot
      end

      # Reads the snapshot for the given file, raising if the file does not exist.
      def read_file(file_id : FileId) : FileSnapshot
        snapshot = @file_inputs[file_id]? || raise MissingInputError.new(file_id)
        record_dependency(QueryId.new(:input, file_id))
        snapshot
      end

      # Removes a file from the input set.
      def remove_file(file_id : FileId) : Bool
        return false unless @file_inputs.has_key?(file_id)

        bump_revision
        @file_inputs.delete(file_id)
        @input_changed_at.delete(file_id)
        @input_set_changed_at = @current_revision
        @parsed_cache.delete(file_id)

        if @symbol_cache.delete(file_id)
          @symbol_cache_order.delete(file_id)
        end

        @occurrence_cache.delete(file_id)
        @require_cache.delete(file_id)

        @workspace_symbols_cache = nil

        remove_persisted_symbol(file_id)
        true
      end

      # Returns the parsed representation of a file, using the cache if available.
      def parsed_document(file_id : FileId) : ParsedDocument
        query_id = QueryId.new(:parsed_document, file_id)
        if cached = @parsed_cache[file_id]?
          if cached.verified_at == @current_revision
            record_dependency(query_id)
            return cached.value
          end
          unless dependencies_stale?(cached.dependencies)
            cached.verified_at = @current_revision
            record_dependency(query_id)
            return cached.value
          end
        end

        parsed, dependencies = compute_query(query_id) do
          snapshot = read_file(file_id)
          parse(snapshot.text)
        end

        entry = QueryEntry.new(parsed, @current_revision, @current_revision, dependencies)
        @parsed_cache[file_id] = entry
        record_dependency(query_id)
        parsed
      end

      # Returns the symbol index for a file, using memory or disk cache when possible.
      def symbol_index(file_id : FileId) : SymbolIndex
        query_id = QueryId.new(:symbol_index, file_id)
        if cached = @symbol_cache[file_id]?
          if cached.verified_at == @current_revision
            record_dependency(query_id)
            touch_symbol_cache(file_id)
            return cached.value
          end
          unless dependencies_stale?(cached.dependencies)
            cached.verified_at = @current_revision
            record_dependency(query_id)
            touch_symbol_cache(file_id)
            return cached.value
          end
        end

        if payload = load_symbol_payload(file_id)
          raise MissingInputError.new(file_id) unless @file_inputs.has_key?(file_id)

          dependency = Dependency.new(QueryId.new(:input, file_id), @input_changed_at[file_id])
          sym_index = SymbolIndex.new(payload.symbols)
          occ_index = OccurrenceIndex.new(payload.occurrences)
          req_index = RequireIndex.new(payload.requires)

          entry = QueryEntry.new(sym_index, @current_revision, @current_revision, [dependency])
          @symbol_cache[file_id] = entry
          @occurrence_cache[file_id] = QueryEntry.new(occ_index, @current_revision, @current_revision, [dependency])
          @require_cache[file_id] = QueryEntry.new(req_index, @current_revision, @current_revision, [dependency])
          touch_symbol_cache(file_id)
          record_dependency(query_id)
          return sym_index
        end

        index, dependencies = compute_query(query_id) do
          parsed = parsed_document(file_id)
          semantic_symbol_index(file_id) || build_symbol_index(parsed)
        end

        entry = QueryEntry.new(index, @current_revision, @current_revision, dependencies)
        @symbol_cache[file_id] = entry
        touch_symbol_cache(file_id)
        persist_symbol_index(file_id, index)
        record_dependency(query_id)
        index
      end

      # Returns occurrence index for a file (references, reads/writes).
      def occurrence_index(file_id : FileId) : OccurrenceIndex
        query_id = QueryId.new(:occurrence_index, file_id)
        if cached = @occurrence_cache[file_id]?
          if cached.verified_at == @current_revision
            record_dependency(query_id)
            return cached.value
          end
          unless dependencies_stale?(cached.dependencies)
            cached.verified_at = @current_revision
            record_dependency(query_id)
            return cached.value
          end
        end

        # Compute via symbol_index to populate semantic caches.
        symbol_index(file_id)
        cached = @occurrence_cache[file_id]?
        raise MissingInputError.new(file_id) unless cached
        record_dependency(query_id)
        cached.value
      end

      # Returns require edges for a file.
      def require_index(file_id : FileId) : RequireIndex
        query_id = QueryId.new(:require_index, file_id)
        if cached = @require_cache[file_id]?
          if cached.verified_at == @current_revision
            record_dependency(query_id)
            return cached.value
          end
          unless dependencies_stale?(cached.dependencies)
            cached.verified_at = @current_revision
            record_dependency(query_id)
            return cached.value
          end
        end

        symbol_index(file_id)
        cached = @require_cache[file_id]?
        raise MissingInputError.new(file_id) unless cached
        record_dependency(query_id)
        cached.value
      end

      # Aggregates symbol indexes for the entire workspace.
      def workspace_symbols : Hash(FileId, SymbolIndex)
        if cached = @workspace_symbols_cache
          if cached.verified_at == @current_revision
            record_dependency(QueryId.new(:workspace_symbols, nil))
            return cached.value
          end
          unless dependencies_stale?(cached.dependencies)
            cached.verified_at = @current_revision
            record_dependency(QueryId.new(:workspace_symbols, nil))
            return cached.value
          end
        end

        query_id = QueryId.new(:workspace_symbols, nil)
        result, dependencies = compute_query(query_id) do
          @workspace_symbols_calls += 1
          record_dependency(QueryId.new(:input_set, nil))
          result = {} of FileId => SymbolIndex
          @file_inputs.each_key do |file_id|
            result[file_id] = symbol_index(file_id)
          end
          result
        end

        @workspace_symbols_cache = QueryEntry.new(result, @current_revision, @current_revision, dependencies)
        record_dependency(query_id)
        result
      end

      # Returns a snapshot of the currently cached entries.
      def cache_snapshot : Hash(String, Int32)
        {
          "parsed_cache"             => @parsed_cache.size,
          "symbol_cache"             => @symbol_cache.size,
          "workspace_symbols_cached" => @workspace_symbols_cache.nil? ? 0 : 1,
        }
      end

      # Clears every cached entry and resets the workspace cache.
      def clear_caches : Nil
        @parsed_cache.clear
        @symbol_cache.clear
        @occurrence_cache.clear
        @require_cache.clear
        @symbol_cache_order.clear
        @workspace_symbols_cache = nil
      end

      # Resets execution counters.
      def reset_counters : Nil
        @parse_calls = 0_i64
        @symbol_index_calls = 0_i64
        @workspace_symbols_calls = 0_i64
      end

      private def parse(text : String) : ParsedDocument
        @parse_calls += 1

        tokens = [] of String
        errors = [] of String

        text.each_line.with_index do |line, idx|
          stripped = line.strip
          next if stripped.empty?

          tokens.concat(stripped.split(/\s+/))
          errors << "Trailing whitespace on line #{idx + 1}" if line.ends_with?(" ")
        end

        ParsedDocument.new(tokens, errors)
      end

      private def build_symbol_index(parsed : ParsedDocument) : SymbolIndex
        @symbol_index_calls += 1

        symbols = parsed.tokens.select do |token|
          first = token[0]?
          first && first.ascii_letter?
        end.map { |tok| Semantic::SymbolInfo.new(tok, "identifier") }

        SymbolIndex.new(symbols.uniq { |s| s.name })
      end

      private def semantic_symbol_index(file_id : FileId) : SymbolIndex?
        return nil unless worker = @semantic_worker

        snapshot = read_file(file_id)
        result = worker.symbols_for(file_id.path, snapshot.text)
        @symbol_index_calls += 1
        dep = Dependency.new(QueryId.new(:input, file_id), @input_changed_at[file_id])
        symbol_index = SymbolIndex.new(result.symbols)
        @occurrence_cache[file_id] = QueryEntry.new(OccurrenceIndex.new(result.occurrences), @current_revision, @current_revision, [dep])
        @require_cache[file_id] = QueryEntry.new(RequireIndex.new(result.requires), @current_revision, @current_revision, [dep])
        symbol_index
      rescue Exception
        nil
      end

      private def enforce_symbol_cache_limit : Nil
        limit = @config.max_in_memory_symbols
        return if limit <= 0

        while @symbol_cache_order.size > limit
          evicted_id = @symbol_cache_order.shift
          next unless evicted_id
          @symbol_cache.delete(evicted_id)
        end
      end

      private def persist_symbol_index(file_id : FileId, index : SymbolIndex) : Nil
        return unless @config.persist_symbols

        snapshot = @file_inputs[file_id]?
        return unless snapshot

        path = index_path_for(file_id)
        response_dir = File.dirname(path)
        FileUtils.mkdir_p(response_dir) unless Dir.exists?(response_dir)

        occurrences = @occurrence_cache[file_id]?.try(&.value.occurrences) || [] of Semantic::Occurrence
        requires = @require_cache[file_id]?.try(&.value.requires) || [] of Semantic::RequireEdge

        payload = PersistedSymbolPayload.new(snapshot.version, index.symbols, occurrences, requires)
        File.write(path, payload.to_json)
        @persisted_versions[file_id] = snapshot.version
      rescue IO::Error
        # Persistence failures should not break runtime behaviour.
      end

      private def load_symbol_payload(file_id : FileId) : PersistedSymbolPayload?
        return nil unless @config.persist_symbols

        snapshot = @file_inputs[file_id]?
        return nil unless snapshot

        payload = load_persisted_payload(file_id)
        return nil unless payload
        return nil unless payload.version == snapshot.version

        @persisted_versions[file_id] = payload.version
        payload
      end

      private def load_persisted_payload(file_id : FileId) : PersistedSymbolPayload?
        return nil unless @config.persist_symbols

        path = index_path_for(file_id)
        return nil unless File.exists?(path)

        content = File.read(path)
        PersistedSymbolPayload.from_json(content)
      rescue IO::Error | JSON::ParseException
        nil
      end

      private def remove_persisted_symbol(file_id : FileId) : Nil
        return unless @config.persist_symbols

        path = index_path_for(file_id)
        File.delete(path) if File.exists?(path)
        @persisted_versions.delete(file_id)
      rescue IO::Error
        # Ignore removal errors.
      end

      private def persisted_version(file_id : FileId) : Int64?
        return @persisted_versions[file_id]? if @persisted_versions.has_key?(file_id)

        payload = load_persisted_payload(file_id)
        version = payload.try(&.version)
        @persisted_versions[file_id] = version if version
        version
      end

      private def index_path_for(file_id : FileId) : String
        digest = Digest::SHA1.hexdigest(file_id.path)
        File.join(@config.index_directory, digest[0, 2], "#{digest}.json")
      end

      private def ensure_index_directory : Nil
        return unless @config.persist_symbols

        FileUtils.mkdir_p(@config.index_directory) unless Dir.exists?(@config.index_directory)
      end

      private def bump_revision : Nil
        @current_revision += 1
      end

      private def compute_query(query_id : QueryId, &block)
        if @active_query_ids.includes?(query_id)
          raise "Cycle detected for #{query_id}"
        end

        @active_query_ids.add(query_id)
        @dependency_stack << [] of Dependency

        dependencies = [] of Dependency
        popped = false

        begin
          value = yield
          dependencies = @dependency_stack.pop
          popped = true
          {value, dependencies}
        ensure
          @active_query_ids.delete(query_id)
          @dependency_stack.pop unless popped
        end
      end

      private def dependencies_stale?(dependencies : Array(Dependency)) : Bool
        dependencies.any? do |dependency|
          current = current_changed_at(dependency.id)
          current.nil? || current != dependency.changed_at
        end
      end

      private def record_dependency(id : QueryId) : Nil
        return if @dependency_stack.empty?

        changed_at = current_changed_at(id) || @current_revision
        @dependency_stack.last << Dependency.new(id, changed_at)
      end

      private def current_changed_at(id : QueryId) : Int64?
        case id.name
        when :input
          @input_changed_at[id.key.as(FileId)]?
        when :input_set
          @input_set_changed_at
        when :parsed_document
          @parsed_cache[id.key.as(FileId)]?.try(&.changed_at)
        when :symbol_index
          @symbol_cache[id.key.as(FileId)]?.try(&.changed_at)
        when :occurrence_index
          @occurrence_cache[id.key.as(FileId)]?.try(&.changed_at)
        when :require_index
          @require_cache[id.key.as(FileId)]?.try(&.changed_at)
        when :workspace_symbols
          @workspace_symbols_cache.try(&.changed_at)
        else
          nil
        end
      end

      private def touch_symbol_cache(file_id : FileId) : Nil
        @symbol_cache_order.delete(file_id)
        @symbol_cache_order << file_id
        enforce_symbol_cache_limit
      end
    end
  end
end
