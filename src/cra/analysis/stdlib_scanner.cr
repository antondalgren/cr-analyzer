require "./database"
require "./indexer"
require "log"

module CRA
  module Analysis
    class StdlibScanner
      Log = ::Log.for(self)

      def initialize(@database : Database)
      end

      def scan
        sdk_path = Path.new("/usr/share/crystal/src")
        unless Dir.exists?(sdk_path)
          Log.warn { "Crystal SDK not found at #{sdk_path}" }
          return
        end

        Log.info { "Scanning Crystal SDK at #{sdk_path}" }

        # We prioritize files that likely contain macro definitions
        # But ideally we scan everything.
        # For performance, maybe we can just scan top-level files or specific directories?
        # Or just scan everything in background.

        Dir.glob(sdk_path.join("**/*.cr").to_s) do |file_path|
          begin
            # Only index if it contains "macro" keyword to speed up?
            # Or just index everything.
            # Let's try to be fast.

            # content = File.read(file_path)
            # next unless content.includes?("macro")

            # Actually, we need types too for resolution.

            index_file(file_path)
          rescue ex
            Log.warn { "Failed to index SDK file #{file_path}: #{ex.message}" }
          end
        end
      end

      private def index_file(path : String)
        content = File.read(path)
        parser = Crystal::Parser.new(content)
        node = parser.parse

        uri = "file://#{path}"
        indexer = Indexer.new(@database, uri)
        node.accept(indexer)
      end
    end
  end
end
