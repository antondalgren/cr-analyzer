require "./salsa"

module CRA
  module Indexer
    # Configuration options that drive the behaviour of the workspace indexer.
    struct Config
      DEFAULT_IGNORED_DIRECTORIES = {".git", ".crystal", ".cache", ".idea", "tmp", "log", "node_modules"}
      DEFAULT_WORKSPACE_ROOTS     = {"."}
      DEFAULT_DEPENDENCY_ROOTS    = {"lib"}

      getter root_path : String
      getter workspace_roots : Array(String)
      getter dependency_roots : Array(String)
      getter stdlib_paths : Array(String)?
      getter include_stdlib : Bool
      getter warm_caches : Bool
      getter ignore_directories : Set(String)
      getter follow_symlinks : Bool
      getter skip_hidden_directories : Bool

      def initialize(
        root_path : String,
        workspace_roots : Enumerable(String) = DEFAULT_WORKSPACE_ROOTS,
        dependency_roots : Enumerable(String) = DEFAULT_DEPENDENCY_ROOTS,
        stdlib_paths : Array(String)? = nil,
        include_stdlib : Bool = true,
        warm_caches : Bool = true,
        ignore_directories : Enumerable(String) = DEFAULT_IGNORED_DIRECTORIES,
        follow_symlinks : Bool = false,
        skip_hidden_directories : Bool = true,
      )
        @root_path = File.expand_path(root_path)
        @workspace_roots = workspace_roots.to_a
        @dependency_roots = dependency_roots.to_a
        @stdlib_paths = stdlib_paths
        @include_stdlib = include_stdlib
        @warm_caches = warm_caches
        @ignore_directories = ignore_directories.to_set
        @follow_symlinks = follow_symlinks
        @skip_hidden_directories = skip_hidden_directories
      end
    end

    # Progress information emitted while indexing.
    struct ProgressReport
      getter indexed_files : Int32
      getter total_files : Int32
      getter current_path : String
      getter phase : String

      def initialize(@indexed_files : Int32, @total_files : Int32, @current_path : String, @phase : String)
      end
    end

    # Summary returned once indexing is complete.
    struct IndexResult
      getter indexed_files : Int32
      getter skipped_files : Int32
      getter failed_files : Int32
      getter errors : Array(String)

      def initialize(@indexed_files : Int32, @skipped_files : Int32, @failed_files : Int32, @errors : Array(String))
      end
    end

    # Performs the initial scan of a Crystal workspace and hydrates the Salsa database.
    class WorkspaceIndexer
      alias ProgressCallback = Proc(ProgressReport, Nil)

      # Internal representation of a discovered source file.
      private struct FileEntry
        getter absolute_path : String
        getter base_path : String
        getter label : String
        getter phase : String

        def initialize(@absolute_path : String, @base_path : String, @label : String, @phase : String)
        end
      end

      getter config : Config
      getter database : CRA::Salsa::Database

      def initialize(@database : CRA::Salsa::Database, config : Config)
        @config = config
      end

      # Performs indexing and optionally yields progress information to +progress+.
      def index!(progress : ProgressCallback? = nil) : IndexResult
        files = collect_source_files
        total = files.size
        indexed = 0
        skipped = 0
        failed = 0
        errors = [] of String

        files.each do |entry|
          progress.try &.call(ProgressReport.new(indexed, total, entry.absolute_path, entry.phase))
          begin
            snapshot = build_snapshot(entry.absolute_path)
            if snapshot
              file_id = CRA::Salsa::FileId.new(file_id_path(entry))
              @database.write_file(file_id, snapshot.text, snapshot.version)
              warm(file_id) if @config.warm_caches
              indexed += 1
            else
              skipped += 1
            end
          rescue ex
            failed += 1
            errors << format_error(entry.absolute_path, ex)
          end
        end

        IndexResult.new(indexed, skipped, failed, errors)
      end

      private def collect_source_files : Array(FileEntry)
        files = [] of FileEntry

        excluded = dependency_roots

        workspace_roots.each do |root|
          files.concat(list_files_for_root(root, "workspace", "workspace", excluded))
        end

        dependency_roots.each do |root|
          files.concat(list_files_for_root(root, "dep", "dependencies"))
        end

        stdlib_roots.each do |root|
          label = "stdlib:#{File.basename(root)}"
          files.concat(list_files_for_root(root, label, "stdlib"))
        end

        files
      end

      private def workspace_roots : Array(String)
        @config.workspace_roots.map { |sub| File.expand_path(sub, @config.root_path) }
      end

      private def dependency_roots : Array(String)
        @config.dependency_roots.map { |sub| File.expand_path(sub, @config.root_path) }.select { |root| Dir.exists?(root) }
      end

      private def stdlib_roots : Array(String)
        return [] of String unless @config.include_stdlib

        if paths = @config.stdlib_paths
          return paths.select { |p| Dir.exists?(p) }
        end

        discover_stdlib_paths
      end

      private def list_files_for_root(root : String, label : String, phase : String, excluded_roots : Array(String) = [] of String) : Array(FileEntry)
        files = [] of FileEntry
        traverse(root, label, phase, root, excluded_roots, files)
        files
      end

      private def traverse(path : String, label : String, phase : String, base_path : String, excluded_roots : Array(String), files : Array(FileEntry)) : Nil
        info = file_info(path) || return

        if info.directory?
          return if excluded_roots.any? { |excluded| path == excluded || path.starts_with?(excluded + File::SEPARATOR) }
          basename = File.basename(path)
          return if ignore_directory?(basename)
          Dir.each_child(path) do |child|
            traverse(File.join(path, child), label, phase, base_path, excluded_roots, files)
          end
        elsif info.file? && crystal_source?(path)
          files << FileEntry.new(path, base_path, label, phase)
        end
      rescue ex
        # Swallow directory traversal errors but log them for diagnostics.
        files << FileEntry.new(path, base_path, label, phase) if ex.is_a?(SystemError) && crystal_source?(path)
      end

      private def file_info(path : String) : File::Info?
        File.info(path, follow_symlinks: @config.follow_symlinks)
      rescue File::Error
        nil
      end

      private def ignore_directory?(name : String) : Bool
        return true if @config.ignore_directories.includes?(name)
        return true if @config.skip_hidden_directories && name.starts_with?(".")
        false
      end

      private def crystal_source?(path : String) : Bool
        File.extname(path) == ".cr"
      end

      private def build_snapshot(path : String) : CRA::Salsa::FileSnapshot?
        text = File.read(path)
        version = file_info(path).try(&.modification_time.to_unix) || Time.utc.to_unix
        CRA::Salsa::FileSnapshot.new(text, version)
      rescue File::Error
        nil
      end

      private def relative_path(path : String, base : String) : String
        Path[path].relative_to(Path[base]).to_s
      rescue ArgumentError
        path
      end

      private def file_id_path(entry : FileEntry) : String
        relative = relative_path(entry.absolute_path, entry.base_path)

        if entry.phase == "dependencies"
          parts = relative.split(File::SEPARATOR)
          shard = parts.shift?
          return shard ? "#{entry.label}:#{shard}:#{parts.join(File::SEPARATOR)}" : "#{entry.label}:#{relative}"
        end

        "#{entry.label}:#{relative}"
      end

      private def discover_stdlib_paths : Array(String)
        paths = [] of String

        begin
          stdout = IO::Memory.new
          stderr = IO::Memory.new
          Process.run("crystal", ["env", "CRYSTAL_PATH"], output: stdout, error: stderr)
          candidate = stdout.to_s.strip
          raw_paths = candidate.empty? ? (ENV["CRYSTAL_PATH"]? || "") : candidate
          paths = raw_paths.split(path_separator)
        rescue Exception
          paths = [] of String
        end

        paths.select { |p| !p.empty? && Dir.exists?(p) }
      end

      private def path_separator : Char
        # Crystal does not expose PATH separator; infer from platform.
        File::SEPARATOR == '\\' ? ';' : ':'
      end

      private def warm(file_id : CRA::Salsa::FileId) : Nil
        # Prime caches so LSP queries stay warm after initial indexing.
        @database.parsed_document(file_id)
        @database.symbol_index(file_id)
      rescue Exception
        # Keep indexing resilient; cache warm-up is best-effort.
      end

      private def format_error(path : String, ex : Exception) : String
        "#{relative_path(path, @config.root_path)}: #{ex.class.name} - #{ex.message}"
      end
    end
  end
end
