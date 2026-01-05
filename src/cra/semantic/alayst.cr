require "log"
require "compiler/crystal/syntax"
require "./ast"

class Crystal::Path
  def full : String
    names.join("::")
  end
end

module CRA::Psi
  class SemanticIndex < Crystal::Visitor
    Log = ::Log.for(self)

    @roots : Array(PsiElement) = [] of PsiElement

    # Stack to keep track of current owner while visiting
    @owner_stack : Array(Module | Class) = [] of Module | Class

    @current_file : String? = nil

    def visit(node : Crystal::ASTNode) : Bool
      # Log.info { "Visiting node: #{node.class} at #{node.location.inspect}" }
      true
    end

    def visit(node : Crystal::Expressions) : Bool
      # Log.info { "Visiting Expressions node with #{node.expressions.size} expressions" }
      node.accept_children(self)
      false
    end

    def visit(node : Crystal::ModuleDef) : Bool
      Log.info { "Visiting ModuleDef node: #{node.name}" }
      name = qualified_name(node.name)
      parent = @owner_stack.last.as(Module) if !@owner_stack.empty? && @owner_stack.last.is_a?(Module)
      if !parent
        # Check if module is defined in file with namespaced module
        if parent_name = parent_name_of(name)
          parent = find_module(parent_name, true)
        end
      end
      module_element = find_module(name)
      if !module_element
        loc = to_location(node)
        module_element = Module.new(
          file: @current_file,
          name: name,
          classes: [] of Class,
          methods: [] of Method,
          owner: parent,
          location: loc
        )
        attach module_element
      end
      @owner_stack << module_element
      node.accept_children(self)
      @owner_stack.pop
      false
    end

    def visit(node : Crystal::ClassDef) : Bool
      Log.info { "Visiting ClassDef node: #{node.name} with parent #{node.superclass}" }
      name = qualified_name(node.name)
      parent = @owner_stack.last? if !@owner_stack.empty?
      if !parent
        # Check if class is defined in file with namespaced module
        if parent_name = parent_name_of(name)
          parent = find_class(parent_name) || find_module(parent_name, true)
        end
      end
      class_element = find_class(name)
      if !class_element
        loc = to_location(node)
        class_element = Class.new(
          file: @current_file,
          name: name,
          methods: [] of Method,
          # parent: node.superclass && node.superclass.to_s || "Object",
          owner: parent,
          location: loc
        )
        attach class_element
      end
      @owner_stack << class_element
      node.accept_children(self)
      @owner_stack.pop
      false
    end

    def visit(node : Crystal::Def) : Bool
      Log.info { "Visiting Def node: #{node.name}" }
      if owner = @owner_stack.last?
        loc = to_location(node)
        method_element = Method.new(
          file: @current_file,
          name: node.name,
          owner: owner,
          return_type: node.return_type ? node.return_type.to_s : "Nil",
          location: loc
        )
        attach method_element
      end
      false
    end

    def attach(element : PsiElement)
      if @owner_stack.empty?
        @roots << element
      else
        owner = @owner_stack.last
        case owner
        when Module
          case element
          when Module
            @roots << element unless @roots.includes?(element)
          when Class
            owner.classes << element
          when Method
            owner.methods << element
          end
        when Class
          case element
          when Method
            owner.methods << element
          when Class, Module
            @roots << element unless @roots.includes?(element)
          end
        end
      end
    end

    def enter(file : String)
      @current_file = file
      @owner_stack.clear
    end

    def find_module(name : String, create_on_missing : Bool = false) : Module?
      @roots.each do |root|
        if root.is_a?(Module) && root.name == name
          return root.as(Module)
        end
      end
      nil unless create_on_missing
      if create_on_missing
        module_element = Module.new(
          file: @current_file,
          name: name,
          classes: [] of Class,
          methods: [] of Method,
          owner: nil
        )
        @roots << module_element
        return module_element
      end
    end

    def find_class(name : String) : Class?
      @roots.each do |root|
        if root.is_a?(Class) && root.name == name
          return root.as(Class)
        end
        if root.is_a?(Module)
          root.classes.each do |cls|
            if cls.name == name
              return cls
            end
          end
        end
      end
      nil
    end

    private def find_type(name : String) : Module | Class | Nil
      find_class(name) || find_module(name)
    end

    private def find_methods_in(owner : Module | Class, name : String) : Array(Method)
      owner.methods.select { |meth| meth.name == name }
    end

    def find_definitions(node : Crystal::ASTNode, context : String? = nil) : Array(PsiElement)
      results = [] of PsiElement
      case node
      when Crystal::ModuleDef
        if resolved = resolve_type(node.name.full, context)
          results << resolved
        end
      when Crystal::ClassDef
        if resolved = resolve_type(node.name.full, context)
          results << resolved
        end
      when Crystal::Def
        if context && (owner = find_type(context))
          results.concat(find_methods_in(owner, node.name))
        end
      when Crystal::Call
        if obj = node.obj
          if obj.is_a?(Crystal::Path)
            if owner = resolve_type(obj.full, context)
              results.concat(find_methods_in(owner, node.name))
            end
          end
        elsif context && (owner = find_type(context))
          results.concat(find_methods_in(owner, node.name))
        end
      when Crystal::Path
        # Handle path nodes if necessary
        Log.info { "Finding definitions for Path node: #{node.names.to_s} #{node.to_s}" }
        if resolved = resolve_type(node.full, context)
          results << resolved
        end
      when Crystal::Generic
        if resolved = resolve_type(node.name.full, context)
          results << resolved
        end
      end
      results
    end

    def dump_roots
      @roots.each do |root|
        dump_element(root, 0)
      end
    end

    def dump_element(element : PsiElement, indent : Int32)
      indentation = "  " * indent
      Log.info { "#{indentation}- #{element.class.name}: #{element.name} (file: #{element.file})" }
      case element
      when Module
        element.classes.each do |cls|
          dump_element(cls, indent + 1)
        end
        element.methods.each do |meth|
          dump_element(meth, indent + 1)
        end
      when Class
        element.methods.each do |meth|
          dump_element(meth, indent + 1)
        end
      end
    end

    private def to_location(node : Crystal::ASTNode) : Location
      if loc = node.location
        end_loc = node.end_location
        start_line = loc.line_number - 1
        start_col = loc.column_number - 1
        end_line = (end_loc.try(&.line_number) || loc.line_number) - 1
        end_col = (end_loc.try(&.column_number) || loc.column_number) - 1
        Location.new(start_line, start_col, end_line, end_col)
      else
        Location.new(0, 0, 0, 0)
      end
    end

    private def qualified_name(path : Crystal::Path) : String
      name = path.full
      return name if name.includes?("::")
      return name if @owner_stack.empty?

      owner = @owner_stack.last
      "#{owner.name}::#{name}"
    end

    private def parent_name_of(name : String) : String?
      parts = name.split("::")
      return nil if parts.size < 2
      parts[0...-1].join("::")
    end

    private def resolve_type(name : String, context : String?) : Module | Class | Nil
      if context && !context.empty? && !name.includes?("::")
        if resolved = find_type("#{context}::#{name}")
          return resolved
        end
      end
      find_type(name)
    end
  end
end
