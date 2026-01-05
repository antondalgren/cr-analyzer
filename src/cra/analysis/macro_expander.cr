require "compiler/crystal/syntax"
require "./models"
require "./macro_interpreter"

module CRA
  module Analysis
    class MacroExpander
      # Returns a tuple of (Virtual URI, Content) if the call is a supported macro
      def self.expand(node : Crystal::Call, file_uri : String, database : Database, scope : ContainerSymbol) : {String, String}?
        # 1. Try to find user-defined macro
        macro_sym = find_macro(node.name, scope, database)

        if macro_sym
          begin
            interpreter = MacroInterpreter.new(macro_sym.node, node)
            expanded = interpreter.interpret

            line = node.location.try(&.line_number) || 0
            col = node.location.try(&.column_number) || 0
            macro_uri = "crystal-macro:#{file_uri.sub("file://", "")}/#{node.name}/#{line}_#{col}.cr"

            return {macro_uri, expanded}
          rescue ex
            # Log error?
            # puts "Macro expansion failed for #{node.name}: #{ex.message}"
          end
        end

        # 2. Fallback to built-in hardcoded macros (if not found in DB)
        case node.name
        when "property", "getter", "setter"
          expand_accessor(node, file_uri)
        when "record"
          expand_record(node, file_uri)
        else
          nil
        end
      end

      private def self.find_macro(name : String, scope : Symbol, database : Database) : MacroSymbol?
        # Simple lookup: check current scope, then parents, then root
        current = scope
        while current
          if current.is_a?(ContainerSymbol)
            found = current.children.find { |s| s.name == name && s.is_a?(MacroSymbol) }
            return found.as(MacroSymbol) if found
          end
          current = current.parent
        end

        # Check root if not reached
        found = database.root.children.find { |s| s.name == name && s.is_a?(MacroSymbol) }
        return found.as(MacroSymbol) if found

        # Check Object (implicit base)
        object_sym = database.find_type("Object")
        if object_sym
          found = object_sym.children.find { |s| s.name == name && s.is_a?(MacroSymbol) }
          return found.as(MacroSymbol) if found
        end

        nil
      end

      private def self.expand_record(node : Crystal::Call, file_uri : String)
        return nil if node.args.empty?

        name_arg = node.args.first
        # record name can be a Path (Constant)
        struct_name = name_arg.to_s

        properties = node.args[1..-1]

        io = IO::Memory.new
        io.puts "struct #{struct_name}"

        # Generate getters
        properties.each do |prop|
          if prop.is_a?(Crystal::TypeDeclaration)
             io.puts "  getter #{prop.var} : #{prop.declared_type}"
          elsif prop.is_a?(Crystal::Var)
             io.puts "  getter #{prop.name}"
          end
        end

        # Generate initialize
        io.print "  def initialize("
        properties.each_with_index do |prop, i|
          io.print ", " if i > 0
          if prop.is_a?(Crystal::TypeDeclaration)
             io.print "@#{prop.var} : #{prop.declared_type}"
          elsif prop.is_a?(Crystal::Var)
             io.print "@#{prop.name}"
          end
        end
        io.puts ")"
        io.puts "  end"

        io.puts "end"

        line = node.location.try(&.line_number) || 0
        col = node.location.try(&.column_number) || 0
        macro_uri = "crystal-macro:#{file_uri.sub("file://", "")}/#{node.name}/#{line}_#{col}.cr"

        {macro_uri, io.to_s}
      end

      private def self.expand_accessor(node : Crystal::Call, file_uri : String)
        io = IO::Memory.new

        node.args.each do |arg|
          expand_single_accessor(io, node.name, arg)
        end

        return nil if io.empty?

        line = node.location.try(&.line_number) || 0
        col = node.location.try(&.column_number) || 0
        macro_uri = "crystal-macro:#{file_uri.sub("file://", "")}/#{node.name}/#{line}_#{col}.cr"

        {macro_uri, io.to_s}
      end

      private def self.expand_single_accessor(io : IO, macro_name : String, arg : Crystal::ASTNode)
        name = ""
        type_decl = nil

        if arg.is_a?(Crystal::TypeDeclaration)
          name = arg.var.to_s
          type_decl = arg.declared_type.to_s
        elsif arg.is_a?(Crystal::Var)
          name = arg.name
        elsif arg.is_a?(Crystal::Call)
          name = arg.name
        elsif arg.is_a?(Crystal::Assign)
           # Handle property x = 1
           target = arg.target
           if target.is_a?(Crystal::Var)
             name = target.name
           elsif target.is_a?(Crystal::TypeDeclaration)
             name = target.var.to_s
             type_decl = target.declared_type.to_s
           end
        end

        return if name.empty?

        case macro_name
        when "getter"
          write_getter(io, name, type_decl)
        when "setter"
          write_setter(io, name, type_decl)
        when "property"
          write_getter(io, name, type_decl)
          write_setter(io, name, type_decl)
        end
      end

      private def self.write_getter(io, name, type)
        if type
          io.puts "def #{name} : #{type}"
        else
          io.puts "def #{name}"
        end
        io.puts "  @#{name}"
        io.puts "end"
      end

      private def self.write_setter(io, name, type)
        if type
          io.puts "def #{name}=(#{name} : #{type})"
        else
          io.puts "def #{name}=(#{name})"
        end
        io.puts "  @#{name} = #{name}"
        io.puts "end"
      end
    end
  end
end


