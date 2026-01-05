require "./models"
require "compiler/crystal/syntax"

module CRA
  module Analysis
    class Database
      getter root : ProgramSymbol
      getter virtual_files : Hash(String, String)

      def initialize
        @root = ProgramSymbol.new
        @virtual_files = {} of String => String
      end

      # Find a type by its fully qualified name (e.g. "Foo::Bar")
      def find_type(fqn : String) : TypeSymbol?
        parts = fqn.split("::").reject(&.empty?)
        current : Symbol = @root

        parts.each do |part|
          if current.is_a?(ContainerSymbol)
            found = current.find(part)
            if found
              current = found
            else
              return nil
            end
          else
            return nil
          end
        end

        current.is_a?(TypeSymbol) ? current : nil
      end

      # Remove all symbols defined in the given file URI
      def delete_from_file(uri : String)
        prune(@root, uri)
      end

      private def prune(container : ContainerSymbol, uri : String)
        # Iterate backwards to safely remove while iterating
        i = container.children.size - 1
        while i >= 0
          child = container.children[i]

          if child.is_a?(ContainerSymbol)
            prune(child, uri)
            # If the container is empty and it belongs to the file, remove it
            # Note: If it belongs to another file but is empty, we keep it (it might be a namespace defined elsewhere)
            # But if it belongs to THIS file and is empty, it means all its contents (from this file) are gone
            # and it has no contents from other files.
            if child.children.empty? && child.location.uri == uri
              container.children.delete_at(i)
            end
          else
            # Leaf node (Method, Var, etc.)
            if child.location.uri == uri
              container.children.delete_at(i)
            end
          end

          i -= 1
        end
      end

      # Helper to print the tree for debugging
      def dump_tree(node : Symbol = @root, indent = 0)
        puts " " * indent + "#{node.kind}: #{node.name}"
        if node.is_a?(ContainerSymbol)
          node.children.each { |c| dump_tree(c, indent + 2) }
        end
      end
    end
  end
end
