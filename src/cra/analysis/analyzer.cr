require "./database"
require "./indexer"
require "./stdlib_scanner"

module CRA
  module Analysis
    class Analyzer
      getter database : Database
      getter stdlib_scanner : StdlibScanner

      def initialize
        @database = Database.new
        @stdlib_scanner = StdlibScanner.new(@database)
      end

      def scan_stdlib
        @stdlib_scanner.scan
      end

      def analyze_file(path : String, content : String? = nil)
        uri = "file://#{path}"
        content ||= File.read(path)

        # Remove old symbols for this file
        @database.delete_from_file(uri)

        # Parse and index
        parser = Crystal::Parser.new(content)
        node = parser.parse

        indexer = Indexer.new(@database, uri)
        node.accept(indexer)
      end

      def find_definition(uri : String, line : Int32, col : Int32) : Array(CRA::Types::Location)
        # TODO: Implement definition lookup using the database
        # For now, we can just return empty or implement a basic lookup
        [] of CRA::Types::Location
      end
    end
  end
end
