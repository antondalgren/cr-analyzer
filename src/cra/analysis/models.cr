require "../types"

module CRA
  module Analysis
    enum SymbolKind
      Module
      Class
      Struct
      Enum
      Def
      Macro
      InstanceVar
      ClassVar
      LocalVar
      Parameter
      BlockArg
    end

    enum Visibility
      Public
      Protected
      Private
    end

    abstract class Symbol
      property name : String
      property location : CRA::Types::Location
      property kind : SymbolKind
      property parent : Symbol?
      property visibility : Visibility = Visibility::Public

      def initialize(@name : String, @kind : SymbolKind, @location : CRA::Types::Location, @parent : Symbol? = nil)
      end

      def full_name : String
        if (p = @parent) && !p.is_a?(ProgramSymbol)
          "#{p.full_name}::#{@name}"
        else
          @name
        end
      end
    end

    # Represents a scope that can contain other symbols (e.g. Module, Class, Method)
    abstract class ContainerSymbol < Symbol
      property children : Array(Symbol) = [] of Symbol

      def add(symbol : Symbol)
        symbol.parent = self
        @children << symbol
      end

      def find(name : String) : Symbol?
        @children.find { |c| c.name == name }
      end

      def resolve(name : String) : Symbol?
        if found = find(name)
          return found
        elsif p = @parent
          # If we are in a method, we might look up to the class
          # But if we are in a class, we might look up to the module or superclass
          # For now, simple lexical scoping up the tree
          if p.is_a?(ContainerSymbol)
             return p.resolve(name)
          end
        end
        nil
      end
    end

    class ProgramSymbol < ContainerSymbol
      def initialize
        # Program has no location really, or we can make a dummy one
        dummy_loc = CRA::Types::Location.new(uri: "", range: CRA::Types::Range.new(CRA::Types::Position.new(0, 0), CRA::Types::Position.new(0, 0)))
        super("main", SymbolKind::Module, dummy_loc)
      end

      def full_name
        ""
      end
    end

    class TypeSymbol < ContainerSymbol
      property superclass_name : String?
      property included_modules : Array(String) = [] of String
    end

    class MethodSymbol < ContainerSymbol
      property args : Array(VariableSymbol) = [] of VariableSymbol
      property return_type_restriction : String?
    end

    class MacroSymbol < Symbol
      property node : Crystal::Macro

      def initialize(name, location, parent, @node)
        super(name, SymbolKind::Macro, location, parent)
      end
    end

    class VariableSymbol < Symbol
      property type_restriction : String?
      property inferred_type : String?
    end
  end
end
