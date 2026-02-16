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

private def hover_request(uri : String, position : CRA::Types::Position) : CRA::Types::HoverRequest
  payload = {
    jsonrpc: "2.0",
    id: 1,
    method: "textDocument/hover",
    params: {
      textDocument: {uri: uri},
      position: {line: position.line, character: position.character},
    },
  }.to_json

  CRA::Types::Message.from_json(payload).as(CRA::Types::HoverRequest)
end

describe CRA::Workspace do
  it "returns hover signature and documentation" do
    code = <<-CRYSTAL
      class Greeter
        # Says hello.
        def greet(name)
        end
      end

      def call
        greeter = Greeter.new
        greeter.greet("hi")
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "greet(\"hi\")")
      pos = position_for(code, index + "greet".size - 1)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      contents = hover.not_nil!.contents.as_h
      contents["kind"].as_s.should eq("markdown")
      value = contents["value"].as_s
      value.should contain("def Greeter#greet(name)")
      value.should contain("Says hello.")
    end
  end

  it "shows Bool type for local assigned from boolean literal" do
    code = <<-CRYSTAL
      def call
        ipv6_native = false
        ipv6_native
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover_bool.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "ipv6_native", 1)
      pos = position_for(code, index)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("ipv6_native : Bool")
    end
  end

  it "shows String type for local assigned from string literal" do
    code = <<-CRYSTAL
      def call
        name = "hello"
        name
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover_string.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "name", 1)
      pos = position_for(code, index)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("name : String")
    end
  end

  it "shows Int32 type for local assigned from integer literal" do
    code = <<-CRYSTAL
      def call
        count = 42
        count
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover_int.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "count", 1)
      pos = position_for(code, index)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("count : Int32")
    end
  end

  it "shows inferred type for local assigned from class method call" do
    code = <<-CRYSTAL
      class Resolver
        def self.resolve(name) : String
        end
      end

      def call
        result = Resolver.resolve("foo")
        result
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover_class_method.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "result", 1)
      pos = position_for(code, index)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("result : String")
    end
  end

  it "shows inferred type for local assigned from class-level [] constructor" do
    code = <<-CRYSTAL
      class Slice(T)
      end

      def call
        ipv4 = Slice[127u8, 0u8, 0u8, 1u8]
        ipv4
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover_bracket.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "ipv4", 1)
      pos = position_for(code, index)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("ipv4 : Slice(UInt8)")
    end
  end

  it "shows inferred type for local assigned from .new" do
    code = <<-CRYSTAL
      class Greeter
        def greet(name)
        end
      end

      def call
        greeter = Greeter.new
        greeter
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover_new.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "greeter", 1)
      pos = position_for(code, index)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("greeter : Greeter")
    end
  end
end
