require "compiler/crystal/syntax"
require "./ast_node_extensions"

module CRA
  class DocumentSymbolsIndex < Crystal::Visitor
    @current_uri : String?
    @container_stack : Array(String)
    @symbol_stack : Array(Types::DocumentSymbol)
    @type_stack : Array(Types::DocumentSymbol)
    @field_names_by_container : Hash(String, Hash(String, Bool))
    def initialize
      # Document uri to symbols mapping
      @symbols = {} of String => Array(Types::DocumentSymbol)
      @current_uri = nil
      @container_stack = [] of String
      @symbol_stack = [] of Types::DocumentSymbol
      @type_stack = [] of Types::DocumentSymbol
      @field_names_by_container = {} of String => Hash(String, Bool)
    end

    def enter(uri : String)
      @current_uri = uri
      @symbols[uri] = [] of Types::DocumentSymbol
      @container_stack.clear
      @symbol_stack.clear
      @type_stack.clear
      @field_names_by_container.clear
    end

    def visit(node : Crystal::ASTNode) : Bool
      true
    end

    def visit(node : Crystal::Expressions) : Bool
      node.accept_children(self)
      false
    end

    def visit(node : Crystal::ModuleDef) : Bool
      symbol = document_symbol(node, Types::SymbolKind::Module, type_vars_detail(node))
      push_container(node.name.to_s)
      push_symbol(symbol, true)
      node.accept_children(self)
      pop_symbol(true)
      @container_stack.pop
      false
    end

    def visit(node : Crystal::Def) : Bool
      symbol = document_symbol(node, def_symbol_kind, def_detail(node))
      push_symbol(symbol)
      node.accept_children(self)
      pop_symbol
      false
    end

    def visit(node : Crystal::ClassDef) : Bool
      symbol = document_symbol(node, Types::SymbolKind::Class, type_vars_detail(node))
      push_container(node.name.to_s)
      push_symbol(symbol, true)
      node.accept_children(self)
      pop_symbol(true)
      @container_stack.pop
      false
    end

    def visit(node : Crystal::EnumDef) : Bool
      symbol = document_symbol(node, Types::SymbolKind::Enum)
      push_container(node.name.to_s)
      push_symbol(symbol, true)
      node.members.each do |member|
        next unless member.is_a?(Crystal::Arg)
        member_symbol = document_symbol(member, Types::SymbolKind::EnumMember)
        push_symbol(member_symbol)
        pop_symbol
      end
      node.accept_children(self)
      pop_symbol(true)
      @container_stack.pop
      false
    end

    def visit(node : Crystal::TypeDeclaration) : Bool
      record_field(node.var, node.declared_type)
      false
    end

    def visit(node : Crystal::Assign) : Bool
      record_field(node.target)
      true
    end

    def visit(node : Crystal::OpAssign) : Bool
      record_field(node.target)
      true
    end

    def visit(node : Crystal::MultiAssign) : Bool
      node.targets.each { |target| record_field(target) }
      true
    end

    def [](uri : String) : Array(Types::DocumentSymbol)
      @symbols[uri] ||= [] of Types::DocumentSymbol
    end

    def symbol_informations(uri : String) : Array(Types::SymbolInformation)
      symbols = self[uri]
      flat = [] of Types::SymbolInformation
      symbols.each do |symbol|
        flatten_symbol(symbol, flat, nil, uri)
      end
      flat
    end

    private def current_container : String?
      @container_stack.last?
    end

    private def push_container(name : String)
      if name.includes?("::")
        @container_stack << name
      elsif parent = @container_stack.last?
        @container_stack << "#{parent}::#{name}"
      else
        @container_stack << name
      end
    end

    private def push_symbol(symbol : Types::DocumentSymbol, type_symbol : Bool = false)
      if @current_uri
        if parent = @symbol_stack.last?
          children = parent.children || [] of Types::DocumentSymbol
          children << symbol
          parent.children = children
        else
          @symbols[@current_uri] << symbol
        end
      else
        raise "You must call enter(uri) before adding symbols"
      end
      @symbol_stack << symbol
      @type_stack << symbol if type_symbol
    end

    private def pop_symbol(type_symbol : Bool = false)
      @symbol_stack.pop?
      @type_stack.pop? if type_symbol
    end

    private def document_symbol(node : Crystal::ASTNode, kind : Types::SymbolKind, detail : String? = nil) : Types::DocumentSymbol
      name = node.name.to_s
      Types::DocumentSymbol.new(
        name: name,
        kind: kind,
        range: range_for(node),
        selection_range: selection_range_for(node),
        detail: detail
      )
    end

    private def range_for(node : Crystal::ASTNode) : Types::Range
      if loc = node.location
        end_loc = node.end_location
        if end_loc.nil?
          name_loc = node.name_location || loc
          size = node.name_size
          if size > 0
            end_loc = Crystal::Location.new(
              filename: name_loc.filename,
              line_number: name_loc.line_number,
              column_number: name_loc.column_number + size - 1
            )
            loc = name_loc
          else
            end_loc = loc
          end
        end
        return Types::Range.new(
          start_position: Types::Position.new(line: loc.line_number - 1, character: loc.column_number - 1),
          end_position: Types::Position.new(line: end_loc.line_number - 1, character: end_loc.column_number - 1)
        )
      end
      Types::Range.new(
        start_position: Types::Position.new(line: 0, character: 0),
        end_position: Types::Position.new(line: 0, character: 0)
      )
    end

    private def selection_range_for(node : Crystal::ASTNode) : Types::Range
      loc = node.name_location || node.location
      size = node.name_size
      if loc && size > 0
        end_loc = Crystal::Location.new(
          filename: loc.filename,
          line_number: loc.line_number,
          column_number: loc.column_number + size - 1
        )
        return Types::Range.new(
          start_position: Types::Position.new(line: loc.line_number - 1, character: loc.column_number - 1),
          end_position: Types::Position.new(line: end_loc.line_number - 1, character: end_loc.column_number - 1)
        )
      end
      range_for(node)
    end

    private def def_symbol_kind : Types::SymbolKind
      @type_stack.empty? ? Types::SymbolKind::Function : Types::SymbolKind::Method
    end

    private def def_detail(node : Crystal::Def) : String?
      parts = node.args.map(&.to_s)
      detail = parts.empty? ? "" : "(#{parts.join(", ")})"
      if return_type = node.return_type
        suffix = return_type.to_s
        detail = detail.empty? ? ": #{suffix}" : "#{detail} : #{suffix}"
      end
      detail.empty? ? nil : detail
    end

    private def type_vars_detail(node : Crystal::ModuleDef | Crystal::ClassDef) : String?
      type_vars = node.type_vars || [] of String
      return nil if type_vars.empty?
      "(#{type_vars.join(", ")})"
    end

    private def record_field(target : Crystal::ASTNode, declared_type : Crystal::ASTNode? = nil)
      type_symbol = @type_stack.last?
      container = current_container
      return unless type_symbol && container

      name = nil
      kind = Types::SymbolKind::Field
      case target
      when Crystal::InstanceVar
        name = target.name
      when Crystal::ClassVar
        name = target.name
      else
        return
      end
      return if name.empty?

      fields = (@field_names_by_container[container] ||= {} of String => Bool)
      return if fields[name]?
      fields[name] = true

      detail = declared_type ? declared_type.to_s : nil
      field_symbol = Types::DocumentSymbol.new(
        name: name,
        kind: kind,
        range: range_for(target),
        selection_range: selection_range_for(target),
        detail: detail
      )
      children = type_symbol.children || [] of Types::DocumentSymbol
      children << field_symbol
      type_symbol.children = children
    end

    private def flatten_symbol(
      symbol : Types::DocumentSymbol,
      flat : Array(Types::SymbolInformation),
      container : String?,
      uri : String
    )
      name = symbol.name
      if detail = symbol.detail
        suffix = detail.starts_with?("(") || detail.starts_with?(":") ? detail : " #{detail}"
        name = "#{name}#{suffix}"
      end
      flat << Types::SymbolInformation.new(
        name: name,
        kind: symbol.kind,
        location: Types::Location.new(uri: uri, range: symbol.range),
        container_name: container
      )

      return unless children = symbol.children
      next_container = container ? "#{container}::#{symbol.name}" : symbol.name
      children.each do |child|
        flatten_symbol(child, flat, next_container, uri)
      end
    end
  end
end
