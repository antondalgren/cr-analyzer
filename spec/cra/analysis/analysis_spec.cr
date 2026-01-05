require "../../spec_helper"
require "../../../src/cra/analysis/indexer"
require "../../../src/cra/analysis/resolver"

describe CRA::Analysis do
  describe "Indexer" do
    it "indexes a simple module with a class and method" do
      code = <<-CRYSTAL
        module MyModule
          class MyClass
            def my_method(a : Int32)
              b = 10
            end
          end
        end
      CRYSTAL

      parser = Crystal::Parser.new(code)
      node = parser.parse

      db = CRA::Analysis::Database.new
      indexer = CRA::Analysis::Indexer.new(db, "file:///test.cr")
      node.accept(indexer)

      # Check Module
      mod = db.root.find("MyModule")
      mod.should_not be_nil
      mod.should be_a(CRA::Analysis::TypeSymbol)
      mod.as(CRA::Analysis::TypeSymbol).kind.should eq(CRA::Analysis::SymbolKind::Module)

      # Check Class
      cls = mod.as(CRA::Analysis::ContainerSymbol).find("MyClass")
      cls.should_not be_nil
      cls.should be_a(CRA::Analysis::TypeSymbol)
      cls.as(CRA::Analysis::TypeSymbol).kind.should eq(CRA::Analysis::SymbolKind::Class)

      # Check Method
      meth = cls.as(CRA::Analysis::ContainerSymbol).find("my_method")
      meth.should_not be_nil
      meth.should be_a(CRA::Analysis::MethodSymbol)

      # Check Args
      arg = meth.as(CRA::Analysis::MethodSymbol).find("a")
      arg.should_not be_nil
      arg.as(CRA::Analysis::VariableSymbol).kind.should eq(CRA::Analysis::SymbolKind::Parameter)
      arg.as(CRA::Analysis::VariableSymbol).type_restriction.should eq("Int32")

      # Check Local Var
      local = meth.as(CRA::Analysis::ContainerSymbol).find("b")
      local.should_not be_nil
      local.as(CRA::Analysis::VariableSymbol).kind.should eq(CRA::Analysis::SymbolKind::LocalVar)
    end
  end

  describe "Resolver" do
    it "resolves symbols in lexical scope" do
      code = <<-CRYSTAL
        module A
          class B
            def foo
              x = 1
            end
          end
        end
      CRYSTAL

      parser = Crystal::Parser.new(code)
      node = parser.parse
      db = CRA::Analysis::Database.new
      indexer = CRA::Analysis::Indexer.new(db, "file:///test.cr")
      node.accept(indexer)

      resolver = CRA::Analysis::Resolver.new(db)

      # Navigate to the method scope
      mod_a = db.root.find("A").as(CRA::Analysis::ContainerSymbol)
      class_b = mod_a.find("B").as(CRA::Analysis::ContainerSymbol)
      method_foo = class_b.find("foo").as(CRA::Analysis::ContainerSymbol)

      # Resolve 'x' inside 'foo'
      sym = resolver.resolve("x", method_foo)
      sym.should_not be_nil
      sym.try(&.name).should eq("x")

      # Resolve 'B' inside 'foo' (should find it in parent scope)
      sym_b = resolver.resolve("B", method_foo)
      sym_b.should_not be_nil
      sym_b.try(&.name).should eq("B")
    end

    it "resolves symbols via inheritance" do
       code = <<-CRYSTAL
        class Parent
          def inherited_method
          end
        end

        class Child < Parent
          def my_method
             # should see inherited_method
          end
        end
      CRYSTAL

      parser = Crystal::Parser.new(code)
      node = parser.parse
      db = CRA::Analysis::Database.new
      indexer = CRA::Analysis::Indexer.new(db, "file:///test.cr")
      node.accept(indexer)

      resolver = CRA::Analysis::Resolver.new(db)

      child = db.root.find("Child").as(CRA::Analysis::ContainerSymbol)
      my_method = child.find("my_method").as(CRA::Analysis::ContainerSymbol)

      # Resolve 'inherited_method' from inside 'Child#my_method'
      sym = resolver.resolve("inherited_method", my_method)
      sym.should_not be_nil
      sym.try(&.name).should eq("inherited_method")
      sym.try(&.parent.try(&.name)).should eq("Parent")
    end

    it "handles modules defined across multiple sources" do
      code1 = <<-CRYSTAL
        module MyMod
          def method_one; end
        end
      CRYSTAL

      code2 = <<-CRYSTAL
        module MyMod
          def method_two; end
        end
      CRYSTAL

      db = CRA::Analysis::Database.new

      # Index first part
      parser1 = Crystal::Parser.new(code1)
      node1 = parser1.parse
      indexer1 = CRA::Analysis::Indexer.new(db, "file:///file1.cr")
      node1.accept(indexer1)

      # Index second part
      parser2 = Crystal::Parser.new(code2)
      node2 = parser2.parse
      indexer2 = CRA::Analysis::Indexer.new(db, "file:///file2.cr")
      node2.accept(indexer2)

      mod = db.root.find("MyMod")
      mod.should_not be_nil
      mod.as(CRA::Analysis::ContainerSymbol).children.size.should eq(2)
      mod.as(CRA::Analysis::ContainerSymbol).find("method_one").should_not be_nil
      mod.as(CRA::Analysis::ContainerSymbol).find("method_two").should_not be_nil
    end

    it "handles nested paths in definitions" do
      code = <<-CRYSTAL
        module A
        end

        class A::B
        end
      CRYSTAL

      parser = Crystal::Parser.new(code)
      node = parser.parse
      db = CRA::Analysis::Database.new
      indexer = CRA::Analysis::Indexer.new(db, "file:///test.cr")
      node.accept(indexer)

      mod_a = db.root.find("A")
      mod_a.should_not be_nil

      class_b = mod_a.as(CRA::Analysis::ContainerSymbol).find("B")
      class_b.should_not be_nil
    end

    it "resolves fully qualified paths" do
      db = CRA::Analysis::Database.new
      code = <<-CRYSTAL
        module A
          class B
            def foo; end
          end
        end

        class User
          def use
            # Should resolve A::B
          end
        end
      CRYSTAL

      node = Crystal::Parser.new(code).parse
      indexer = CRA::Analysis::Indexer.new(db, "file:///test.cr")
      node.accept(indexer)

      resolver = CRA::Analysis::Resolver.new(db)
      user_class = db.root.find("User").as(CRA::Analysis::ContainerSymbol)

      # Resolve "A::B"
      sym = resolver.resolve("A::B", user_class)
      sym.should_not be_nil
      sym.try(&.full_name).should eq("A::B")
    end

    it "supports re-indexing by removing old symbols" do
      db = CRA::Analysis::Database.new
      uri = "file:///test.cr"

      # Initial content: Class A with method foo
      code1 = <<-CRYSTAL
        class A
          def foo; end
        end
      CRYSTAL

      node1 = Crystal::Parser.new(code1).parse
      indexer1 = CRA::Analysis::Indexer.new(db, uri)
      node1.accept(indexer1)

      class_a = db.root.find("A").as(CRA::Analysis::ContainerSymbol)
      class_a.find("foo").should_not be_nil

      # Re-index: Class A with method bar (foo is deleted)
      code2 = <<-CRYSTAL
        class A
          def bar; end
        end
      CRYSTAL

      # Step 1: Delete old symbols
      db.delete_from_file(uri)

      # Verify deletion
      # A should be gone because it was defined in uri and became empty
      db.root.find("A").should be_nil

      # Step 2: Index new content
      node2 = Crystal::Parser.new(code2).parse
      indexer2 = CRA::Analysis::Indexer.new(db, uri)
      node2.accept(indexer2)

      class_a_new = db.root.find("A").as(CRA::Analysis::ContainerSymbol)
      class_a_new.should_not be_nil
      class_a_new.find("foo").should be_nil
      class_a_new.find("bar").should_not be_nil
    end

    it "expands macros like property into virtual files" do
      db = CRA::Analysis::Database.new
      uri = "file:///test.cr"
      code = <<-CRYSTAL
        class Person
          property name : String
        end
      CRYSTAL

      node = Crystal::Parser.new(code).parse
      indexer = CRA::Analysis::Indexer.new(db, uri)
      node.accept(indexer)

      person = db.root.find("Person").as(CRA::Analysis::ContainerSymbol)

      # Should have 'name' (getter) and 'name=' (setter)
      getter_sym = person.find("name")
      getter_sym.should_not be_nil
      getter_sym.should be_a(CRA::Analysis::MethodSymbol)

      setter_sym = person.find("name=")
      setter_sym.should_not be_nil

      # Check location URI
      loc = getter_sym.as(CRA::Analysis::Symbol).location
      loc.uri.should start_with("crystal-macro:")
      loc.uri.should contain("property")

      # Check virtual file content
      content = db.virtual_files[loc.uri]?
      content.should_not be_nil
      content.try(&.should contain("def name : String"))
    end

    it "preserves shared containers during re-indexing" do
      db = CRA::Analysis::Database.new
      uri1 = "file:///1.cr"
      uri2 = "file:///2.cr"

      # File 1: module M; def a; end
      code1 = "module M; def a; end; end"
      node1 = Crystal::Parser.new(code1).parse
      CRA::Analysis::Indexer.new(db, uri1).visit(node1)

      # File 2: module M; def b; end
      code2 = "module M; def b; end; end"
      node2 = Crystal::Parser.new(code2).parse
      CRA::Analysis::Indexer.new(db, uri2).visit(node2)

      mod = db.root.find("M").as(CRA::Analysis::ContainerSymbol)
      mod.find("a").should_not be_nil
      mod.find("b").should_not be_nil

      # Re-index File 1 (remove it)
      db.delete_from_file(uri1)

      # M should still exist because it has content from File 2
      mod = db.root.find("M").as(CRA::Analysis::ContainerSymbol)
      mod.should_not be_nil
      mod.find("a").should be_nil # 'a' should be gone
      mod.find("b").should_not be_nil # 'b' should stay
    end
  end
end
