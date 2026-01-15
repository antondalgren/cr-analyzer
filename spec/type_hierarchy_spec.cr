require "./spec_helper"
require "../src/cr-analyzer"

describe "Type hierarchy" do
  it "prepares and resolves super/sub types" do
    with_tmpdir do |dir|
      source = <<-CR
        class Base
        end

        module Mix
        end

        class Child < Base
          include Mix
        end

        class GrandChild < Child
        end
      CR
      file_path = File.join(dir, "hierarchy.cr")
      File.write(file_path, source)

      ws = workspace_for(dir)
      uri = "file://#{file_path}"

      prepare = CRA::Types::TypeHierarchyPrepareRequest.new(
        method: "textDocument/prepareTypeHierarchy",
        id: 1,
        text_document: CRA::Types::TextDocumentIdentifier.new(uri: uri),
        position: CRA::Types::Position.new(line: 6, character: 8) # inside Child name
      )

      items = ws.prepare_type_hierarchy(prepare)
      items.size.should be > 0
      child_item = items.find { |i| i.name == "Child" }.not_nil!

      supertypes_req = CRA::Types::TypeHierarchySupertypesRequest.new(
        method: "typeHierarchy/supertypes",
        id: 2,
        item: child_item
      )
      supers = ws.type_hierarchy_supertypes(supertypes_req).map(&.name)
      supers.should contain("Base")
      supers.should contain("Mix")

      subtypes_req = CRA::Types::TypeHierarchySubtypesRequest.new(
        method: "typeHierarchy/subtypes",
        id: 3,
        item: CRA::Types::TypeHierarchyItem.new(
          name: "Base",
          kind: CRA::Types::SymbolKind::Class,
          uri: uri,
          range: child_item.range,
          selection_range: child_item.selection_range
        )
      )
      subs = ws.type_hierarchy_subtypes(subtypes_req).map(&.name)
      subs.should contain("Child")
      subs.should contain("GrandChild")
    end
  end
end
