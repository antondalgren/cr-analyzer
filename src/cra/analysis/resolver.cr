require "./models"
require "./database"

module CRA
  module Analysis
    class Resolver
      def initialize(@database : Database)
      end

      def resolve(name : String, context : Symbol) : Symbol?
        # Handle qualified paths
        if name.includes?("::")
          return resolve_path(name, context)
        end

        # 1. Local lookup (lexical scope)
        if sym = resolve_lexical(name, context)
          return sym
        end

        # 2. Inheritance lookup (if context is in a class/module)
        # We need to find the enclosing class
        enclosing_type = find_enclosing_type(context)
        if enclosing_type
           return resolve_inheritance(name, enclosing_type)
        end

        nil
      end

      private def resolve_path(path : String, context : Symbol) : Symbol?
        if path.starts_with?("::")
           return @database.find_type(path)
        end

        parts = path.split("::")
        first_part = parts.first

        # Resolve the first component using standard rules (lexical, inheritance)
        start_symbol = resolve(first_part, context)

        return nil unless start_symbol

        # Traverse the rest
        current = start_symbol
        parts[1..-1].each do |part|
           return nil unless current.is_a?(ContainerSymbol)
           found = current.find(part)
           return nil unless found
           current = found
        end

        current
      end

      private def resolve_lexical(name : String, context : Symbol?) : Symbol?
        return nil unless context

        if context.is_a?(ContainerSymbol)
          if found = context.find(name)
            return found
          end
        end

        resolve_lexical(name, context.parent)
      end

      private def find_enclosing_type(symbol : Symbol?) : TypeSymbol?
        return nil unless symbol
        return symbol if symbol.is_a?(TypeSymbol)
        find_enclosing_type(symbol.parent)
      end

      private def resolve_inheritance(name : String, type : TypeSymbol) : Symbol?
        # Check superclass
        if superclass_name = type.superclass_name
           # Resolve superclass symbol
           # This is tricky because superclass_name might be unqualified or fully qualified
           # For now, assume we can find it in the database or it's in the same scope?
           # Let's try to find it via the database root for now (assuming FQN or top level)

           # TODO: Better superclass resolution
           superclass = @database.find_type(superclass_name)
           if superclass
             if found = superclass.find(name)
               return found
             end
             return resolve_inheritance(name, superclass)
           end
        end
        nil
      end
    end
  end
end
