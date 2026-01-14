require "../../spec_helper"
require "../../../src/cra/workspace"

private def index_for(code : String, needle : String, occurrence : Int32 = 0) : Int32
  idx = -1
  (occurrence + 1).times do
    idx = code.index(needle, idx + 1) || raise "needle not found: #{needle}"
  end
  idx
end

private def position_for(code : String, index : Int32) : CRA::Types::Position
  prefix = code[0, index]
  line = prefix.count('\n')
  last_newline = prefix.rindex('\n')
  column = last_newline ? index - last_newline - 1 : index
  CRA::Types::Position.new(line, column)
end

private def range_for(code : String, index : Int32, length : Int32) : CRA::Types::Range
  start_pos = position_for(code, index)
  end_pos = position_for(code, index + length)
  CRA::Types::Range.new(start_position: start_pos, end_position: end_pos)
end

private def prepare_rename_request(uri : String, position : CRA::Types::Position) : CRA::Types::PrepareRenameRequest
  payload = {
    jsonrpc: "2.0",
    id: 1,
    method: "textDocument/prepareRename",
    params: {
      textDocument: {uri: uri},
      position: {line: position.line, character: position.character},
    },
  }.to_json

  CRA::Types::Message.from_json(payload).as(CRA::Types::PrepareRenameRequest)
end

describe CRA::Workspace do
  it "returns a range for local variable rename" do
    code = <<-CRYSTAL
      def example
        foo = 1
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "prepare_rename_local.cr")
      File.write(path, code)

      ws = CRA::Workspace.from_s("file://#{dir}")
      ws.scan

      uri = "file://#{path}"
      index = index_for(code, "foo")
      pos = position_for(code, index + 1)
      request = prepare_rename_request(uri, pos)
      range = ws.prepare_rename(request)

      range.should_not be_nil
      expected = range_for(code, index, 3)
      range.not_nil!.start_position.line.should eq(expected.start_position.line)
      range.not_nil!.start_position.character.should eq(expected.start_position.character)
      range.not_nil!.end_position.line.should eq(expected.end_position.line)
      range.not_nil!.end_position.character.should eq(expected.end_position.character)
    end
  end

  it "returns a range for type path segment" do
    code = <<-CRYSTAL
      module Foo
        class Bar
        end
      end

      def call
        Foo::Bar.new
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "prepare_rename_type.cr")
      File.write(path, code)

      ws = CRA::Workspace.from_s("file://#{dir}")
      ws.scan

      uri = "file://#{path}"
      index = index_for(code, "Foo::Bar")
      pos = position_for(code, index + "Foo::".size + 1)
      request = prepare_rename_request(uri, pos)
      range = ws.prepare_rename(request)

      range.should_not be_nil
      expected = range_for(code, index + "Foo::".size, "Bar".size)
      range.not_nil!.start_position.line.should eq(expected.start_position.line)
      range.not_nil!.start_position.character.should eq(expected.start_position.character)
      range.not_nil!.end_position.line.should eq(expected.end_position.line)
      range.not_nil!.end_position.character.should eq(expected.end_position.character)
    end
  end
end
