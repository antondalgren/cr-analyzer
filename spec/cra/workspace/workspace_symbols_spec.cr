require "../../spec_helper"
require "../../../src/cra/workspace"

describe CRA::Workspace do
  it "returns symbol informations matching query" do
    with_tmpdir do |dir|
      code = <<-CR
      module Alpha
        class Foo
          def bar; end
        end
      end
      CR
      path = File.join(dir, "main.cr")
      File.write(path, code)
      ws = workspace_for(dir)

      request = CRA::Types::Message.from_json(%({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "workspace/symbol",
        "params": {
          "query": "Foo"
        }
      })).as(CRA::Types::WorkspaceSymbolRequest)

      symbols = ws.workspace_symbols(request)
      symbols.any? { |s| s.name == "Foo" && s.kind == CRA::Types::SymbolKind::Class }.should be_true
      symbols.all? { |s| s.location.uri.ends_with?("/main.cr") }.should be_true

      request_bar = CRA::Types::Message.from_json(%({
        "jsonrpc": "2.0",
        "id": 2,
        "method": "workspace/symbol",
        "params": {
          "query": "bar"
        }
      })).as(CRA::Types::WorkspaceSymbolRequest)

      symbols_bar = ws.workspace_symbols(request_bar)
      symbols_bar.any? { |s| s.name == "bar" && s.kind == CRA::Types::SymbolKind::Method }.should be_true
    end
  end
end
