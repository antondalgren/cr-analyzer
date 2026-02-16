module CRA::Psi
  class SemanticIndex
    private def infer_type_ref(
      node : Crystal::ASTNode,
      context : String?,
      scope_def : Crystal::Def?,
      scope_class : Crystal::ClassDef?,
      cursor : Crystal::Location?,
      depth : Int32 = 0
    ) : TypeRef?
      return nil if depth > 4

      if type_ref = type_ref_from_value(node)
        return type_ref
      end

      type_env : TypeEnv? = nil
      case node
      when Crystal::Var
        type_env ||= build_type_env(scope_def, scope_class, cursor)
        if ref = type_env.locals[node.name]?
          ref
        elsif scope_def
          if assign_val = find_local_assignment_value(scope_def, node.name, cursor)
            infer_type_ref(assign_val, context, scope_def, scope_class, cursor, depth + 1)
          end
        end
      when Crystal::InstanceVar
        type_env ||= build_type_env(scope_def, scope_class, cursor)
        type_env.ivars[node.name]?
      when Crystal::ClassVar
        type_env ||= build_type_env(scope_def, scope_class, cursor)
        type_env.cvars[node.name]?
      when Crystal::Path, Crystal::Generic, Crystal::Metaclass, Crystal::Union, Crystal::Self
        type_ref_from_type(node)
      when Crystal::Call
        infer_type_ref_from_call(node, context, scope_def, scope_class, cursor, depth + 1)
      else
        nil
      end
    end

    private def infer_type_ref_from_call(
      call : Crystal::Call,
      context : String?,
      scope_def : Crystal::Def?,
      scope_class : Crystal::ClassDef?,
      cursor : Crystal::Location?,
      depth : Int32
    ) : TypeRef?
      if call.name == "new"
        if obj = call.obj
          return type_ref_from_type(obj)
        end
      end

      receiver_type : TypeRef? = nil
      class_method = false

      if obj = call.obj
        class_method = obj.is_a?(Crystal::Path) || obj.is_a?(Crystal::Generic) || obj.is_a?(Crystal::Metaclass)
        class_method = scope_def && scope_def.receiver ? true : false if obj.is_a?(Crystal::Self)
        receiver_type = infer_type_ref(obj, context, scope_def, scope_class, cursor, depth + 1)
      elsif context
        receiver_type = TypeRef.named(context)
        class_method = scope_def && scope_def.receiver ? true : false
      end

      return nil unless receiver_type
      if call.name == "[]"
        if indexed = infer_index_return_type(receiver_type, call)
          return indexed
        end
      end
      owner = resolve_type_ref(receiver_type, context)
      return nil unless owner

      candidates = find_methods_with_ancestors(owner, call.name, class_method)
      if candidates.empty?
        if class_method && call.name == "[]"
          return infer_class_bracket_type(receiver_type, call)
        end
        return nil
      end

      narrowed = filter_methods_by_arity_strict(candidates, call)
      candidates = narrowed unless narrowed.empty?

      method = if call.block
                 candidates.find { |m| m.return_type_ref.nil? } || candidates.first?
               else
                 candidates.find(&.return_type_ref) || candidates.first?
               end
      return nil unless method
      result = infer_method_return_type(method, receiver_type, call, context, scope_def, scope_class, cursor, depth)
      if result.nil? && (block = call.block)
        result = infer_block_body_type(block, context, scope_def, scope_class, cursor, depth)
      end
      result
    end

    # When a method has no return type and is called with a block,
    # infer the type from the block body's last expression.
    private def infer_block_body_type(
      block : Crystal::Block,
      context : String?,
      scope_def : Crystal::Def?,
      scope_class : Crystal::ClassDef?,
      cursor : Crystal::Location?,
      depth : Int32
    ) : TypeRef?
      body = block.body
      return nil unless body
      last_expr = body.is_a?(Crystal::Expressions) ? body.expressions.last? : body
      return nil unless last_expr
      infer_type_ref(last_expr, context, scope_def, scope_class, cursor, depth + 1)
    end

    # Infers the return type of a class-level [] call (e.g., Slice[1u8, 2u8]).
    # These are typically macros that construct an instance of the receiver type.
    private def infer_class_bracket_type(receiver_type : TypeRef, call : Crystal::Call) : TypeRef?
      name = receiver_type.name
      return receiver_type unless name

      if first_arg = call.args.first?
        if elem_ref = type_ref_from_value(first_arg)
          return TypeRef.named(name, [elem_ref])
        end
      end

      receiver_type
    end

    private def infer_method_return_type(
      method : CRA::Psi::Method,
      receiver_type : TypeRef,
      call : Crystal::Call? = nil,
      context : String? = nil,
      scope_def : Crystal::Def? = nil,
      scope_class : Crystal::ClassDef? = nil,
      cursor : Crystal::Location? = nil,
      depth : Int32 = 0
    ) : TypeRef?
      return nil unless return_ref = method.return_type_ref
      substitutions = type_vars_for_owner(method.owner, receiver_type)
      if call
        infer_free_var_substitutions(method, call, substitutions, context, scope_def, scope_class, cursor, depth)
      end
      substitute_type_ref(return_ref, substitutions, receiver_type)
    end

    private def infer_free_var_substitutions(
      method : CRA::Psi::Method,
      call : Crystal::Call,
      substitutions : Hash(String, TypeRef),
      context : String?,
      scope_def : Crystal::Def?,
      scope_class : Crystal::ClassDef?,
      cursor : Crystal::Location?,
      depth : Int32
    )
      type_var_names = method.free_vars.to_set
      if type_var_names.empty? && (return_ref = method.return_type_ref)
        collect_type_var_candidates(return_ref, method.param_type_refs, type_var_names, context)
      end
      return if type_var_names.empty?

      method.param_type_refs.each_with_index do |param_ref, idx|
        next unless param_ref
        name = param_ref.name
        next unless name
        next if substitutions[name]?
        next unless type_var_names.includes?(name)

        arg = call.args[idx]?
        next unless arg

        if arg_type = infer_type_ref(arg, context, scope_def, scope_class, cursor, depth + 1)
          substitutions[name] = arg_type
        end
      end

      if (block = call.block) && (block_ret_ref = method.block_return_type_ref)
        block_ret_name = block_ret_ref.name
        if block_ret_name && !substitutions[block_ret_name]? && type_var_names.includes?(block_ret_name)
          if body_type = infer_block_body_type(block, context, scope_def, scope_class, cursor, depth)
            substitutions[block_ret_name] = body_type
          end
        end
      end
    end

    private def collect_type_var_candidates(
      return_ref : TypeRef,
      param_type_refs : Array(TypeRef?),
      candidates : Set(String),
      context : String?
    )
      names = [] of String
      collect_type_ref_names(return_ref, names)
      names.each do |name|
        next if resolve_type_name(name, context)
        if param_type_refs.any? { |pr| pr && pr.name == name }
          candidates << name
        end
      end
    end

    private def collect_type_ref_names(type_ref : TypeRef, names : Array(String))
      if type_ref.union?
        type_ref.union_types.each { |member| collect_type_ref_names(member, names) }
        return
      end
      if name = type_ref.name
        names << name
      end
      type_ref.args.each { |arg| collect_type_ref_names(arg, names) }
    end

    private def type_vars_for_owner(owner : PsiElement | Nil, receiver_type : TypeRef) : Hash(String, TypeRef)
      mapping = {} of String => TypeRef
      return mapping unless owner
      defs = @type_defs_by_name[owner.name]?
      return mapping unless defs
      type_vars = defs.values.first.type_vars
      return mapping if type_vars.empty? || receiver_type.args.empty?

      type_vars.each_with_index do |var, idx|
        arg = receiver_type.args[idx]?
        break unless arg
        mapping[var] = arg
      end
      mapping
    end

    private def substitute_type_ref(
      type_ref : TypeRef,
      substitutions : Hash(String, TypeRef),
      receiver_type : TypeRef
    ) : TypeRef
      if type_ref.union?
        types = type_ref.union_types.map { |member| substitute_type_ref(member, substitutions, receiver_type) }
        seen = Set(String).new
        types = types.select { |t| seen.add?(t.display) }
        return types.size == 1 ? types.first : TypeRef.union(types)
      end

      name = type_ref.name
      return receiver_type if name == "self"
      return substitutions[name] if name && substitutions[name]?
      return type_ref if type_ref.args.empty? || name.nil?

      args = type_ref.args.map { |arg| substitute_type_ref(arg, substitutions, receiver_type) }
      TypeRef.named(name, args)
    end

    private def nil_type?(type_ref : TypeRef) : Bool
      return false if type_ref.union?
      name = type_ref.name
      name == "Nil" || name == "::Nil"
    end

    private def infer_index_return_type(receiver_type : TypeRef, call : Crystal::Call) : TypeRef?
      if receiver_type.union?
        types = [] of TypeRef
        receiver_type.union_types.each do |member|
          if indexed = infer_index_return_type(member, call)
            types << indexed
          end
        end
        return nil if types.empty?
        return types.first if types.size == 1
        return TypeRef.union(types)
      end

      name = receiver_type.name
      return nil unless name
      base_name = name.starts_with?("::") ? name[2..] : name
      case base_name
      when "Array", "Slice", "StaticArray", "Deque"
        return nil if receiver_type.args.empty?
        return receiver_type if range_index?(call) || call.args.size > 1
        receiver_type.args.first?
      when "Hash"
        receiver_type.args[1]?
      else
        nil
      end
    end

    private def range_index?(call : Crystal::Call) : Bool
      call.args.any? { |arg| arg.is_a?(Crystal::RangeLiteral) }
    end

    # Resolves a type-like AST node to a known module/class.
    private def resolve_type_node(node : Crystal::ASTNode, context : String?) : CRA::Psi::Module | CRA::Psi::Class | CRA::Psi::Enum | Nil
      case node
      when Crystal::Path
        resolve_path(node, context) || resolve_alias_target(node.full, context)
      when Crystal::Generic
        resolve_type_node(node.name, context)
      when Crystal::Metaclass
        resolve_type_node(node.name, context)
      when Crystal::Union
        node.types.each do |type|
          if resolved = resolve_type_node(type, context)
            return resolved
          end
        end
        nil
      else
        nil
      end
    end

    private def resolve_enum_member(path : Crystal::Path, context : String?) : CRA::Psi::EnumMember?
      names = path.names
      return nil if names.empty?

      if names.size == 1
        if context_enum = resolve_enum(context)
          return context_enum.members.find { |member| member.name == names.first }
        end
        return nil
      end

      member_name = names.last
      enum_name = names[0...-1].join("::")
      enum_type = path.global? ? find_enum(enum_name) : resolve_enum(enum_name, context)
      return nil unless enum_type
      enum_type.members.find { |member| member.name == member_name }
    end

    private def resolve_enum(name : String?) : CRA::Psi::Enum?
      return nil unless name && !name.empty?
      if context = name
        if enum_type = find_enum(context)
          return enum_type
        end
      end
      nil
    end

    private def resolve_enum(name : String, context : String?) : CRA::Psi::Enum?
      if context && !context.empty?
        parts = context.split("::")
        while parts.size > 0
          candidate = (parts + [name]).join("::")
          if resolved = find_enum(candidate)
            return resolved
          end
          parts.pop
        end
      end
      find_enum(name)
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
      when Enum
        element.members.each do |member|
          dump_element(member, indent + 1)
        end
        element.methods.each do |meth|
          dump_element(meth, indent + 1)
        end
      end
    end

    private def find_local_assignment_value(scope_def : Crystal::Def, name : String, cursor : Crystal::Location?) : Crystal::ASTNode?
      collector = AssignmentValueCollector.new(name, cursor)
      scope_def.body.accept(collector)
      collector.value
    end

    private def resolve_path(path : Crystal::Path, context : String?) : CRA::Psi::Module | CRA::Psi::Class | CRA::Psi::Enum | Nil
      name = path.full
      return find_type(name) if path.global?
      resolve_in_context(name, context)
    end

    private def resolve_in_context(name : String, context : String?) : CRA::Psi::Module | CRA::Psi::Class | CRA::Psi::Enum | Nil
      if context && !context.empty?
        parts = context.split("::")
        while parts.size > 0
          candidate = (parts + [name]).join("::")
          if resolved = find_type(candidate)
            return resolved
          end
          parts.pop
        end
      end
      find_type(name)
    end

    private def resolve_alias_target(name : String, context : String?) : CRA::Psi::Module | CRA::Psi::Class | CRA::Psi::Enum | Nil
      if alias_def = resolve_alias_in_context(name, context)
        if target = alias_def.target
          return resolve_type_ref(target, context)
        end
      end
      nil
    end
  end
end
