module CRA
  class Workspace
    # Small macros to reduce duplicated visitor boilerplate.
    module VisitorHelpers
      macro continue_all
        def visit(node : Crystal::ASTNode) : Bool
          true
        end
      end

      macro stop_at(*types)
        {% for type in types %}
          def visit(node : {{type}}) : Bool
            false
          end
        {% end %}
      end

      macro stop_at_def_like
        def visit(node : Crystal::Def) : Bool
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
      end

      macro stop_at_def_like_and_macros
        def visit(node : Crystal::Def) : Bool
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

      macro stop_at_macros
        def visit(node : Crystal::Macro) : Bool
          false
        end
      end
    end
  end
end
