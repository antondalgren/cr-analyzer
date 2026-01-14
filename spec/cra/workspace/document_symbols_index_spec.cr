require "../../spec_helper"
require "../../../src/cra/workspace/document_symbols_index"

private def symbol_named(symbols : Array(CRA::Types::DocumentSymbol), name : String, kind : CRA::Types::SymbolKind)
  symbols.find { |symbol| symbol.name == name && symbol.kind == kind }
end

describe CRA::DocumentSymbolsIndex do
  it "builds a hierarchical symbol tree with type members" do
    code = <<-CRYSTAL
      module A
        class B
          def foo
            @bar = 1
          end
        end

        enum Kind
          One
        end
      end

      class C
        def baz
        end
      end
    CRYSTAL

    program = Crystal::Parser.new(code).parse
    index = CRA::DocumentSymbolsIndex.new
    uri = "file:///test.cr"
    index.enter(uri)
    program.accept(index)

    symbols = index[uri]

    mod_a = symbol_named(symbols, "A", CRA::Types::SymbolKind::Module)
    mod_a.should_not be_nil

    mod_children = mod_a.not_nil!.children.not_nil!
    cls_b = symbol_named(mod_children, "B", CRA::Types::SymbolKind::Class)
    cls_b.should_not be_nil

    cls_children = cls_b.not_nil!.children.not_nil!
    method_foo = symbol_named(cls_children, "foo", CRA::Types::SymbolKind::Method)
    method_foo.should_not be_nil

    field_bar = symbol_named(cls_children, "@bar", CRA::Types::SymbolKind::Field)
    field_bar.should_not be_nil

    enum_kind = symbol_named(mod_children, "Kind", CRA::Types::SymbolKind::Enum)
    enum_kind.should_not be_nil
    enum_children = enum_kind.not_nil!.children.not_nil!
    enum_member = symbol_named(enum_children, "One", CRA::Types::SymbolKind::EnumMember)
    enum_member.should_not be_nil

    cls_c = symbol_named(symbols, "C", CRA::Types::SymbolKind::Class)
    cls_c.should_not be_nil
    cls_c_children = cls_c.not_nil!.children.not_nil!
    method_baz = symbol_named(cls_c_children, "baz", CRA::Types::SymbolKind::Method)
    method_baz.should_not be_nil
  end
end
