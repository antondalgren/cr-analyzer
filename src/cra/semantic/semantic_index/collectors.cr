module CRA::Psi
  class SemanticIndex
    # Collects type hints before the cursor without descending into nested scopes.
    class TypeCollector < Crystal::Visitor
      include TypeRefHelper

      def initialize(
        @env : TypeEnv,
        @cursor : Crystal::Location?,
        @collect_locals : Bool,
        @fill_only : Bool = false,
        @infer_callback : Proc(Crystal::ASTNode, TypeRef?)? = nil,
        @block_hints_callback : Proc(Crystal::Call, TypeRef?, Array(TypeRef))? = nil
      )
      end

      def visit(node : Crystal::ASTNode) : Bool
        true
      end

      def visit(node : Crystal::Call) : Bool
        if block = node.block
          receiver_type = receiver_type_ref(node)
          hints = block_param_type_hints(node, receiver_type)
          if hints.empty? && (cb = @block_hints_callback)
            hints = cb.call(node, receiver_type)
          end
          block.args.each_with_index do |arg, idx|
            type_ref = nil
            if arg.is_a?(Crystal::Arg)
              if restriction = arg.restriction
                type_ref = type_ref_from_type(restriction)
              end
            end
            type_ref ||= hints[idx]?
            assign_type(arg, type_ref) if type_ref
          end
        end
        true
      end

      def visit(node : Crystal::TypeDeclaration) : Bool
        return false unless before_cursor?(node)

        if type_ref = type_ref_from_type(node.declared_type)
          assign_type(node.var, type_ref)
        end
        true
      end

      def visit(node : Crystal::Assign) : Bool
        return false unless before_cursor?(node)

        if type_ref = type_ref_from_value(node.value)
          assign_type(node.target, type_ref)
        else
          type_ref = case value = node.value
                     when Crystal::Var
                       @env.locals[value.name]?
                     when Crystal::InstanceVar
                       @env.ivars[value.name]?
                     when Crystal::ClassVar
                       @env.cvars[value.name]?
                     else
                       nil
                     end
          type_ref ||= @infer_callback.try(&.call(node.value))
          assign_type(node.target, type_ref) if type_ref
        end
        true
      end

      def visit(node : Crystal::OpAssign) : Bool
        return false unless before_cursor?(node)

        if type_ref = type_ref_from_value(node.value)
          assign_type(node.target, type_ref)
        else
          type_ref = case value = node.value
                     when Crystal::Var
                       @env.locals[value.name]?
                     when Crystal::InstanceVar
                       @env.ivars[value.name]?
                     when Crystal::ClassVar
                       @env.cvars[value.name]?
                     else
                       nil
                     end
          type_ref ||= @infer_callback.try(&.call(node.value))
          assign_type(node.target, type_ref) if type_ref
        end
        true
      end

      def visit(node : Crystal::Def) : Bool
        false
      end

      def visit(node : Crystal::ClassDef) : Bool
        false
      end

      def visit(node : Crystal::ModuleDef) : Bool
        false
      end

      def visit(node : Crystal::Macro) : Bool
        false
      end

      def register_arg(arg : Crystal::Arg)
        if restriction = arg.restriction
          if type_ref = type_ref_from_type(restriction)
            @env.locals[arg.name] = type_ref
          end
        end
      end

      private def assign_type(target : Crystal::ASTNode, type_ref : TypeRef)
        case target
        when Crystal::Var
          return unless @collect_locals
          return if @fill_only && @env.locals.has_key?(target.name)
          @env.locals[target.name] = type_ref
        when Crystal::InstanceVar
          return if @fill_only && @env.ivars.has_key?(target.name)
          @env.ivars[target.name] = type_ref
        when Crystal::ClassVar
          return if @fill_only && @env.cvars.has_key?(target.name)
          @env.cvars[target.name] = type_ref
        end
      end

      private def receiver_type_ref(call : Crystal::Call) : TypeRef?
        obj = call.obj
        return nil unless obj

        case obj
        when Crystal::Var
          @env.locals[obj.name]? || @infer_callback.try(&.call(obj))
        when Crystal::InstanceVar
          @env.ivars[obj.name]?
        when Crystal::ClassVar
          @env.cvars[obj.name]?
        when Crystal::Path, Crystal::Generic, Crystal::Metaclass, Crystal::Union, Crystal::Self
          type_ref_from_type(obj)
        else
          type_ref_from_value(obj)
        end
      end

      private def block_param_type_hints(call : Crystal::Call, receiver_type : TypeRef?) : Array(TypeRef)
        return [] of TypeRef unless receiver_type

        method_name = call.name
        name = receiver_type.name
        args = receiver_type.args
        hints = [] of TypeRef

        # Fluent methods that yield the receiver.
        if {"try", "tap", "with", "let", "yield_self"}.includes?(method_name)
          hints << receiver_type
          return hints
        end

        if name
          base = name.starts_with?("::") ? name[2..] : name
          case base
          when "Array", "Slice", "StaticArray", "Deque", "Set"
            if elem = args.first?
              if block_arity_one?(call)
                hints << elem
              elsif block_arity_two?(call)
                hints << elem
                hints << TypeRef.named("Int32")
              end
            end
          when "Hash"
            key = args[0]?
            value = args[1]?
            if block_arity_two?(call)
              hints << (key || receiver_type)
              hints << (value || receiver_type)
            elsif block_arity_one?(call)
              hints << (value || receiver_type)
            end
          end
        end

        hints
      end

      private def block_arity_one?(call : Crystal::Call) : Bool
        block_args = call.block.try(&.args) || [] of Crystal::Arg
        block_args.size == 1
      end

      private def block_arity_two?(call : Crystal::Call) : Bool
        block_args = call.block.try(&.args) || [] of Crystal::Arg
        block_args.size == 2
      end

      private def before_cursor?(node : Crystal::ASTNode) : Bool
        cursor = @cursor
        return true unless cursor
        loc = node.location
        return true unless loc
        loc.line_number < cursor.line_number ||
          (loc.line_number == cursor.line_number && loc.column_number <= cursor.column_number)
      end
    end

    # Collects instance variable assignments inside initialize methods.
    class InitializeCollector < Crystal::Visitor
      def initialize(@collector : TypeCollector)
      end

      def visit(node : Crystal::ASTNode) : Bool
        true
      end

      def visit(node : Crystal::Def) : Bool
        return false unless node.name == "initialize"
        node.args.each { |arg| @collector.register_arg(arg) }
        node.body.accept(@collector)
        false
      end

      def visit(node : Crystal::ClassDef) : Bool
        false
      end

      def visit(node : Crystal::ModuleDef) : Bool
        false
      end

      def visit(node : Crystal::Macro) : Bool
        false
      end
    end

    # Collects instance/class variable assignments from all method bodies in a class.
    class DefIvarCollector < Crystal::Visitor
      def initialize(@collector : TypeCollector)
      end

      def visit(node : Crystal::ASTNode) : Bool
        true
      end

      def visit(node : Crystal::Def) : Bool
        node.body.accept(@collector)
        false
      end

      def visit(node : Crystal::ClassDef) : Bool
        false
      end

      def visit(node : Crystal::ModuleDef) : Bool
        false
      end

      def visit(node : Crystal::EnumDef) : Bool
        false
      end

      def visit(node : Crystal::Macro) : Bool
        false
      end
    end

    # Collects local variable definitions in a def body (args, assigns, type declarations).
    class LocalVarCollector < Crystal::Visitor
      def initialize(@definitions : Hash(String, Crystal::ASTNode), @cursor : Crystal::Location?)
      end

      def visit(node : Crystal::ASTNode) : Bool
        true
      end

      def visit(node : Crystal::Assign) : Bool
        return false unless before_cursor?(node)
        record_target(node.target)
        true
      end

      def visit(node : Crystal::MultiAssign) : Bool
        return false unless before_cursor?(node)
        node.targets.each { |target| record_target(target) }
        true
      end

      def visit(node : Crystal::TypeDeclaration) : Bool
        return false unless before_cursor?(node)
        record_target(node.var)
        true
      end

      def visit(node : Crystal::Block) : Bool
        return false unless cursor_in?(node)
        node.args.each do |arg|
          name = arg.name
          next if name.empty?
          @definitions[name] = arg
        end
        true
      end

      def visit(node : Crystal::Def) : Bool
        false
      end

      def visit(node : Crystal::ClassDef) : Bool
        false
      end

      def visit(node : Crystal::ModuleDef) : Bool
        false
      end

      def visit(node : Crystal::Macro) : Bool
        false
      end

      private def record_target(target : Crystal::ASTNode)
        case target
        when Crystal::Var
          return if target.name.empty?
          @definitions[target.name] = target
        when Crystal::TupleLiteral
          target.elements.each { |elem| record_target(elem) }
        end
      end

      private def before_cursor?(node : Crystal::ASTNode) : Bool
        cursor = @cursor
        return true unless cursor
        loc = node.location
        return true unless loc
        loc.line_number < cursor.line_number ||
          (loc.line_number == cursor.line_number && loc.column_number <= cursor.column_number)
      end

      private def cursor_in?(node : Crystal::ASTNode) : Bool
        cursor = @cursor
        return false unless cursor
        start_loc = node.location
        return false unless start_loc
        end_loc = node.end_location || start_loc
        (cursor.line_number > start_loc.line_number ||
          (cursor.line_number == start_loc.line_number && cursor.column_number >= start_loc.column_number)) &&
          (cursor.line_number < end_loc.line_number ||
            (cursor.line_number == end_loc.line_number && cursor.column_number <= end_loc.column_number))
      end
    end

    # Finds the first instance variable definition (assign or type declaration).
    class InstanceVarDefinitionCollector < Crystal::Visitor
      getter definition : Crystal::ASTNode?

      def initialize(@name : String, @cursor : Crystal::Location?, @include_initialize : Bool)
      end

      def visit(node : Crystal::ASTNode) : Bool
        return false if @definition
        true
      end

      def visit(node : Crystal::TypeDeclaration) : Bool
        return false unless before_cursor?(node)
        record_target(node.var)
        true
      end

      def visit(node : Crystal::Assign) : Bool
        return false unless before_cursor?(node)
        record_target(node.target)
        true
      end

      def visit(node : Crystal::MultiAssign) : Bool
        return false unless before_cursor?(node)
        node.targets.each { |target| record_target(target) }
        true
      end

      def visit(node : Crystal::OpAssign) : Bool
        return false unless before_cursor?(node)
        record_target(node.target)
        true
      end

      def visit(node : Crystal::Def) : Bool
        return false unless @include_initialize && node.name == "initialize"
        node.body.accept(self)
        false
      end

      def visit(node : Crystal::ClassDef) : Bool
        false
      end

      def visit(node : Crystal::ModuleDef) : Bool
        false
      end

      def visit(node : Crystal::Macro) : Bool
        false
      end

      private def record_target(target : Crystal::ASTNode)
        return if @definition
        case target
        when Crystal::InstanceVar
          if target.name == @name
            @definition = target
          end
        when Crystal::TupleLiteral
          target.elements.each { |elem| record_target(elem) }
        end
      end

      private def before_cursor?(node : Crystal::ASTNode) : Bool
        cursor = @cursor
        return true unless cursor
        loc = node.location
        return true unless loc
        loc.line_number < cursor.line_number ||
          (loc.line_number == cursor.line_number && loc.column_number <= cursor.column_number)
      end
    end

    # Collects instance variable names within a class scope.
    class InstanceVarNameCollector < Crystal::Visitor
      getter names : Hash(String, Crystal::ASTNode)

      def initialize
        @names = {} of String => Crystal::ASTNode
      end

      def visit(node : Crystal::ASTNode) : Bool
        true
      end

      def visit(node : Crystal::InstanceVar) : Bool
        name = node.name
        @names[name] = node unless name.empty?
        true
      end

      def visit(node : Crystal::ClassDef) : Bool
        false
      end

      def visit(node : Crystal::ModuleDef) : Bool
        false
      end

      def visit(node : Crystal::EnumDef) : Bool
        false
      end

      def visit(node : Crystal::Macro) : Bool
        false
      end
    end

    # Finds the RHS value of the last assignment to a given local variable before the cursor.
    class AssignmentValueCollector < Crystal::Visitor
      getter value : Crystal::ASTNode?

      def initialize(@name : String, @cursor : Crystal::Location?)
      end

      def visit(node : Crystal::ASTNode) : Bool
        true
      end

      def visit(node : Crystal::Assign) : Bool
        return false unless before_cursor?(node)
        if target = node.target.as?(Crystal::Var)
          if target.name == @name
            @value = node.value
          end
        end
        true
      end

      def visit(node : Crystal::Def) : Bool
        false
      end

      def visit(node : Crystal::ClassDef) : Bool
        false
      end

      def visit(node : Crystal::ModuleDef) : Bool
        false
      end

      def visit(node : Crystal::Macro) : Bool
        false
      end

      private def before_cursor?(node : Crystal::ASTNode) : Bool
        cursor = @cursor
        return true unless cursor
        loc = node.location
        return true unless loc
        loc.line_number < cursor.line_number ||
          (loc.line_number == cursor.line_number && loc.column_number <= cursor.column_number)
      end
    end

    # Collects class variable names within a class scope.
    class ClassVarNameCollector < Crystal::Visitor
      getter names : Hash(String, Crystal::ASTNode)

      def initialize
        @names = {} of String => Crystal::ASTNode
      end

      def visit(node : Crystal::ASTNode) : Bool
        true
      end

      def visit(node : Crystal::ClassVar) : Bool
        name = node.name
        @names[name] = node unless name.empty?
        true
      end

      def visit(node : Crystal::ClassDef) : Bool
        false
      end

      def visit(node : Crystal::ModuleDef) : Bool
        false
      end

      def visit(node : Crystal::EnumDef) : Bool
        false
      end

      def visit(node : Crystal::Macro) : Bool
        false
      end
    end
  end
end
