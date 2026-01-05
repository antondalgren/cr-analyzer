require "./types"
require "uri"
require "log"
require "compiler/crystal/syntax"
require "./semantic/alayst"

class Crystal::ASTNode
  def range : CRA::Types::Range
    location.try do |loc|
      return CRA::Types::Range.new(
        start_position: CRA::Types::Position.new(line: loc.line_number - 1, character: loc.column_number - 1),
        end_position:   CRA::Types::Position.new(line: loc.line_number - 1, character: loc.column_number - 1)
      )
    end
    CRA::Types::Range.new(
      start_position: CRA::Types::Position.new(line: 0, character: 0),
      end_position:   CRA::Types::Position.new(line: 0, character: 0)
    )
  end

  def symbol_kind : CRA::Types::SymbolKind
    case self
    when Crystal::ModuleDef
      CRA::Types::SymbolKind::Module
    when Crystal::ClassDef
      CRA::Types::SymbolKind::Class
    when Crystal::Def
      CRA::Types::SymbolKind::Method
    when Crystal::InstanceVar
      CRA::Types::SymbolKind::Property
    else
      CRA::Types::SymbolKind::String
    end
  end

  def to_symbol_info(uri : String?, container_name : String?) : CRA::Types::SymbolInformation
    CRA::Types::SymbolInformation.new(
      name: name.to_s,
      kind: symbol_kind,
      container_name: container_name,
      location: CRA::Types::Location.new(
        uri: uri || "",
        range: range
      )
    )
  end
end

module CRA
  class NodeFinder < Crystal::Visitor
    @position : Types::Position

    getter node : Crystal::ASTNode?
    @node_path : Array(Crystal::ASTNode)
    @stack : Array(Crystal::ASTNode)

    def initialize(@position : Types::Position)
      @line = @position.line
      @column = @position.character
      @node_path = [] of Crystal::ASTNode
      @stack = [] of Crystal::ASTNode
      @location = Crystal::Location.new(
        filename: "",
        line_number: @line + 1,
        column_number: @column + 1
      )
    end

    def visit(node : Crystal::ASTNode) : Bool
      return false unless contains?(node)
      @stack << node
      @node = node
      @node_path = @stack.dup
      node.accept_children(self)
      @stack.pop
      false
    end

    def enclosing_type_name : String?
      @node_path.reverse_each do |node|
        case node
        when Crystal::ClassDef
          return node.name.full
        when Crystal::ModuleDef
          return node.name.full
        end
      end
      nil
    end

    private def contains?(node : Crystal::ASTNode) : Bool
      return false unless node.location

      loc = node.location.as(Crystal::Location)

      @location = Crystal::Location.new(
        filename: loc.filename,
        line_number: @location.line_number,
        column_number: @location.column_number
      )
      if node.end_location.nil?
        end_loc = Crystal::Location.new(
          filename: loc.filename,
          line_number: loc.line_number,
          column_number: loc.column_number + node.name_size
        )
      else
        end_loc = node.end_location.as(Crystal::Location)
      end

      @location.between?(loc, end_loc)
    end

  end
  class WorkspaceDocument
    getter path : String

    getter program : Crystal::ASTNode?

    def initialize(@uri : URI)
      @path = @uri.path
      parse
    end

    def parse
      lexer = Crystal::Parser.new(File.read(@path))
      @program = lexer.parse
    end

    def node_context(position : Types::Position) : NodeFinder
      finder = NodeFinder.new(position)
      @program.try do |prog|
        prog.accept(finder)
      end
      finder
    end

    def node_at(position : Types::Position) : Crystal::ASTNode?
      node_context(position).node
    end
  end

  module CompletionProvider
    abstract def complete(request : Types::CompletionRequest) : Array(Types::CompletionItem)
  end

  class DocumentSymbolsIndex < Crystal::Visitor
    include CompletionProvider

    @current_uri : String?
    @container : String?
    def initialize
      # Document uri to symbols mapping
      @symbols = {} of String => Array(Types::SymbolInformation)
      @current_uri = nil
    end

    def enter(uri : String)
      @current_uri = uri
      @symbols[uri] = [] of Types::SymbolInformation
    end

    def visit(node : Crystal::ASTNode) : Bool
      # Log.info { "Visiting node: #{node.class} as #{node.location.inspect}" }
      true
    end

    def visit(node : Crystal::Expressions) : Bool
      # Log.info { "Visiting Expressions node with #{node.expressions.size} expressions" }
      node.accept_children(self)
      false
    end

    def visit(node : Crystal::ModuleDef) : Bool
      # Log.info { "Visiting Def node: #{node.name}" }
      symbol node.to_symbol_info(@current_uri, @container)
      @container = node.name.to_s
      node.accept_children(self)
      false
    end

    def visit(node : Crystal::Def) : Bool
      # Log.info { "Visiting Def node: #{node.name}" }
      node.accept_children(self)
      symbol node.to_symbol_info(@current_uri, @container)
      false
    end

    def visit(node : Crystal::ClassDef) : Bool
      # Log.info { "Visiting Def node: #{node.name}" }
      node.accept_children(self)
      symbol node.to_symbol_info(@current_uri, @container)
      @current_parent = node.name.to_s
      false
    end

    def visit(node : Crystal::VarDef) : Bool
      # Log.info { "Visiting VarDef node: #{node.name}" }
      symbol node.to_symbol_info(@current_uri, @container)
      false
    end

    def visit(node : Crystal::InstanceVar) : Bool
      # Log.info { "Visiting InstanceVar node: #{node.name}" }
      symbol node.to_symbol_info(@current_uri, @container)
      false
    end

    def [](uri : String) : Array(CRA::Types::SymbolInformation)
      @symbols[uri] ||= [] of CRA::Types::SymbolInformation
    end


    private def symbol(symbol : CRA::Types::SymbolInformation)
      if @current_uri
        @symbols[@current_uri] << symbol
        # Log.info { "Added symbol #{symbol.name} to #{@current_uri}" }
      else
        raise "You must call enter(uri) before adding symbols"
      end
    end

    def dump
      @symbols.each do |uri, symbols|
        Log.info { "Symbols for #{uri}:" }
        symbols.each do |symbol|
          Log.info { " - #{symbol.name} (kind: #{symbol.kind} container: #{symbol.container_name})" }
        end
      end
    end

    def complete(request : Types::CompletionRequest) : Array(Types::CompletionItem)
      # For simplicity, return a static list of completions
      file = request.text_document.uri
      position = request.position
      symbols = @symbols[file] || [] of CRA::Types::SymbolInformation
      result = [] of Types::CompletionItem
      Log.info { "Providing completions for #{file} at #{position.line}:#{position.character} #{request.context}" }
      request.context.try do |ctx|
        ctx.trigger_character.try do |char|
          Log.info { "Trigger character: #{char}" }
          symbols.each do |symbol|
            Log.info { "Considering symbol #{symbol.name} of kind #{symbol.kind}" }
            if symbol.kind == Types::SymbolKind::Method && char == "."
              Log.info { "Adding method completion for #{symbol.name}" }
              result << Types::CompletionItem.new(
                label: symbol.name,
                kind: Types::CompletionItemKind::Method,
                detail: "Method from #{symbol.container_name || "global"}"
              )
            elsif symbol.kind == Types::SymbolKind::Class && char == "::"
              Log.info { "Adding class completion for #{symbol.name}" }
              result << Types::CompletionItem.new(
                label: symbol.name,
                kind: Types::CompletionItemKind::Class,
                detail: "Class from #{symbol.container_name || "global"}"
              )
            elsif symbol.kind == Types::SymbolKind::Property && char == "@"
              Log.info { "Adding property completion for #{symbol.name}" }
              result << Types::CompletionItem.new(
                label: symbol.name,
                kind: Types::CompletionItemKind::Property,
                detail: "Property from #{symbol.container_name || "global"}"
              )
            end
          end
          return result
        end
      end
      [] of Types::CompletionItem
    end
  end

  class Workspace
    Log = ::Log.for("CRA::Workspace")

    @completion_providers : Array(CompletionProvider) = [] of CompletionProvider
    @documents : Hash(String, WorkspaceDocument) = {} of String => WorkspaceDocument

    def self.from_s(uri : String)
      new(URI.parse(uri))
    end

    def self.from_uri(uri : URI)
      new(uri)
    end

    getter root : URI

    def initialize(@root : URI)
      raise "Only file:// URIs are supported" unless @root.scheme == "file"
      @path = Path.new(@root.path)
      @indexer = DocumentSymbolsIndex.new
      @analyzer = Psi::SemanticIndex.new
      @completion_providers << @indexer
    end

    def indexer : DocumentSymbolsIndex
      @indexer
    end

    def document(uri : String) : WorkspaceDocument?
      @documents[uri] ||= WorkspaceDocument.new(URI.parse(uri))
    end

    def scan
      # Scan the workspace for Crystal files
      Log.info { "Scanning workspace at #{@root}" }

      # sdk = Path.new("/usr/share/crystal").join("src")
      # Dir.glob(sdk.join("**/*.cr").to_s) do |file_path|
      #   Log.info { "Indexing SDK file: #{file_path}" }
      #   lex = Crystal::Parser.new(File.read(file_path))
      #   program = lex.parse
      #   indexer.enter("file://#{file_path}")
      #   @analyzer.enter("file://#{file_path}")
      #   program.accept(indexer)
      #   program.accept(@analyzer)
      # end

      Dir.glob(@path.join("**/*.cr").to_s) do |file_path|
        # Log.info { "Found Crystal file: #{file_path}" }
        lex = Crystal::Parser.new(File.read(file_path))
        program = lex.parse
        # Log.info { "Parsed #{file_path}: #{program.class}" }
        indexer.enter("file://#{file_path}")
        @analyzer.enter("file://#{file_path}")

        program.accept(indexer)
        program.accept(@analyzer)

      rescue ex : Exception
        Log.error { "Error parsing #{file_path}: #{ex.message}" }
        next
      end
      @analyzer.dump_roots
    end

    def complete(request : Types::CompletionRequest) : Array(Types::CompletionItem)
      items = [] of Types::CompletionItem
      @completion_providers.each do |provider|
        items.concat(provider.complete(request))
      end
      items
    end

    def find_definitions(request : Types::DefinitionRequest) : Array(Types::Location)
      file = document request.text_document.uri
      position = request.position
      file.try do |doc|
        finder = doc.node_context(position)
        node = finder.node
        node.try do |n|
          Log.info { "Finding definitions for node: #{n.class} at #{n.location.inspect}" }
          locations = [] of Types::Location
          @analyzer.find_definitions(n, finder.enclosing_type_name).each do |def_node|
            def_loc = def_node.location
            def_file = def_node.file
            next unless def_loc && def_file
            uri = def_file.starts_with?("file://") ? def_file : "file://#{def_file}"
            locations << Types::Location.new(
              uri: uri,
              range: def_loc.to_range
            )
          end
          return locations
        end
      end
      [] of Types::Location
    end
  end
end

# ws = CRA::Workspace.from_s("file:///home/mike/cr-analyzer")
# puts ws.root.inspect

# ws.scan
