require "compiler/crystal/syntax"
require "./models"
require "./database"
require "./macro_expander"

module CRA
  module Analysis
    class Indexer < Crystal::Visitor
      def initialize(@database : Database, @uri : String)
        @scope_stack = [] of ContainerSymbol
        @scope_stack << @database.root
      end

      def visit(node : Crystal::ASTNode)
        true
      end

      def visit(node : Crystal::ModuleDef)
        process_type_def(node, SymbolKind::Module)
      end

      def visit(node : Crystal::ClassDef)
        process_type_def(node, SymbolKind::Class)
      end

      private def process_type_def(node, kind)
        current_scope = @scope_stack.last
        path = node.name

        # Determine starting scope
        target_scope = path.global? ? @database.root : current_scope

        # Traverse/Create path for intermediate modules
        path.names[0...-1].each do |name|
           found = target_scope.find(name)
           unless found
             # Implicitly create missing modules in path
             loc = to_location(node)
             found = TypeSymbol.new(name, SymbolKind::Module, loc, target_scope)
             target_scope.add(found)
           end

           if found.is_a?(ContainerSymbol)
             target_scope = found
           else
             # Error: trying to open a non-container?
             return false
           end
        end

        # Now handle the last part (the actual definition)
        name = path.names.last
        symbol = target_scope.find(name)

        unless symbol
          loc = to_location(node)
          symbol = TypeSymbol.new(name, kind, loc, target_scope)
          if node.is_a?(Crystal::ClassDef) && (superclass = node.superclass)
             symbol.superclass_name = superclass.to_s
          end
          target_scope.add(symbol)
        end

        if symbol.is_a?(ContainerSymbol)
          @scope_stack << symbol

          node.accept_children(self)
          @scope_stack.pop
        end

        false
      end

      def visit(node : Crystal::Def)
        current_scope = @scope_stack.last
        name = node.name

        loc = to_location(node)
        method_sym = MethodSymbol.new(name, SymbolKind::Def, loc, current_scope)

        # Add args
        node.args.each do |arg|
           arg_loc = to_location(arg)
           arg_sym = VariableSymbol.new(arg.name, SymbolKind::Parameter, arg_loc, method_sym)
           if restriction = arg.restriction
             arg_sym.type_restriction = restriction.to_s
           end
           method_sym.add(arg_sym)
           method_sym.args << arg_sym
        end

        if return_type = node.return_type
          method_sym.return_type_restriction = return_type.to_s
        end

        current_scope.add(method_sym)

        @scope_stack << method_sym
        node.accept_children(self)
        @scope_stack.pop

        false
      end

      def visit(node : Crystal::Macro)
        current_scope = @scope_stack.last
        name = node.name
        loc = to_location(node)

        macro_sym = MacroSymbol.new(name, loc, current_scope, node)
        current_scope.add(macro_sym)

        # We don't need to visit children of a macro definition for indexing purposes usually,
        # unless we want to index variables inside it?
        # But macro body is code that is not executed yet.
        # So we skip children.
        false
      end

      def visit(node : Crystal::Call)
        # Check for macro expansion
        if expansion = MacroExpander.expand(node, @uri, @database, @scope_stack.last)
          uri, content = expansion

          # Store virtual file content
          @database.virtual_files[uri] = content

          # Parse and index the expanded content
          begin
            parser = Crystal::Parser.new(content)
            expanded_node = parser.parse
          rescue ex : Crystal::SyntaxException
            puts "Error parsing expanded macro for #{node.name}: #{ex.message}"
            puts "Expanded content:"
            puts content
            return false
          end

          # Index recursively with the NEW URI
          old_uri = @uri
          @uri = uri
          begin
            expanded_node.accept(self)
          ensure
            @uri = old_uri
          end
        end

        true
      end

      def visit(node : Crystal::Assign)
        target = node.target
        if target.is_a?(Crystal::Var)
          current_scope = @scope_stack.last
          name = target.name

          unless current_scope.find(name)
            loc = to_location(target)
            var_sym = VariableSymbol.new(name, SymbolKind::LocalVar, loc, current_scope)
            current_scope.add(var_sym)
          end
        end
        true
      end

      private def to_location(node : Crystal::ASTNode) : CRA::Types::Location
        # Crystal AST uses 1-based lines and columns
        # LSP uses 0-based

        start_line = (node.location.try(&.line_number) || 1) - 1
        start_col = (node.location.try(&.column_number) || 1) - 1
        end_line = (node.end_location.try(&.line_number) || start_line + 1) - 1
        end_col = (node.end_location.try(&.column_number) || start_col + 1) - 1

        CRA::Types::Location.new(
          uri: @uri,
          range: CRA::Types::Range.new(
            CRA::Types::Position.new(start_line, start_col),
            CRA::Types::Position.new(end_line, end_col)
          )
        )
      end
    end
  end
end
