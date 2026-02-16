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

  it "shows inferred type for block parameter from method-call-assigned receiver" do
    code = <<-CRYSTAL
      class Resolver
        def self.resolve(names) : Array(String)
        end
      end

      def call
        results = Resolver.resolve(["a", "b"])
        results.each do |item|
          item
        end
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover_block_param.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "item", 1)
      pos = position_for(code, index)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("item : String")
    end
  end

  it "shows inferred type for block parameter from method block signature" do
    code = <<-CRYSTAL
      class Fetcher
        def self.fetch(& : (String, Int32) -> Nil)
        end
      end

      def call
        Fetcher.fetch do |name, count|
          name
        end
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover_block_sig.cr")
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

  it "shows inferred type for local from generic method return type" do
    code = <<-CRYSTAL
      class Config
        def self.fetch(key : String, default : T) : T forall T
        end
      end

      def call
        env = Config.fetch("MY_ENV", "")
        env
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover_generic.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "env", 1)
      pos = position_for(code, index)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("env : String")
    end
  end

  it "shows inferred type for local from implicit generic return type" do
    code = <<-CRYSTAL
      class Store
        def self.get(key : String, fallback : T) : T
        end
      end

      def call
        count = Store.get("key", 42)
        count
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover_implicit_generic.cr")
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

  it "deduplicates union type when generic resolves to same type" do
    code = <<-CRYSTAL
      class Config
        def self.fetch(key : String, default : T) : String | T forall T
        end
      end

      def call
        env = Config.fetch("MY_ENV", "")
        env
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover_union_dedup.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "env", 1)
      pos = position_for(code, index)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("env : String")
      value.should_not contain("String | String")
    end
  end

  it "infers Array(UInt8) from array literal with typed elements" do
    code = <<-CRYSTAL
      def call
        bytes = [0u8, 1u8, 2u8]
        bytes
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover_array_literal.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "bytes", 1)
      pos = position_for(code, index)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("bytes : Array(UInt8)")
    end
  end

  it "shows inferred type from block body when method has no return type" do
    code = <<-CRYSTAL
      class FileReader
        def self.open(path : String, &)
        end
      end

      class IniParser
        def self.parse(source : FileReader) : Hash(String, String)
        end
      end

      def call
        result = FileReader.open("path.ini") { |file| IniParser.parse(file) }
        result
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover_block_return.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "result", 1)
      pos = position_for(code, index)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("result : Hash(String, String)")
    end
  end

  it "preserves union type when variable is reassigned inside conditional" do
    code = <<-CRYSTAL
      class Env
        def self.fetch(key : String, default : T) : T forall T
        end
      end

      def call
        key = Env.fetch("KEY", [0u8])
        if true
          key = "override"
        end
        key
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover_conditional_union.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "key", 3)
      pos = position_for(code, index)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("Array(UInt8)")
      value.should contain("String")
    end
  end

  it "narrows type inside is_a? check" do
    code = <<-CRYSTAL
      def call(x : String | Int32)
        if x.is_a?(String)
          x
        end
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover_isa.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "x", 2)
      pos = position_for(code, index)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("x : String")
      value.should_not contain("Int32")
    end
  end

  it "narrows nilable type on truthiness check" do
    code = <<-CRYSTAL
      def call(x : String | Nil)
        if x
          x
        end
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover_truthy.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "x", 2)
      pos = position_for(code, index)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("x : String")
      value.should_not contain("Nil")
    end
  end

  it "narrows type with chained && conditions" do
    code = <<-CRYSTAL
      def call(x : String | Nil, y : Int32 | Nil)
        if x && y
          x
        end
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover_and_chain.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "x", 2)
      pos = position_for(code, index)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("x : String")
      value.should_not contain("Nil")
    end
  end

  it "narrows type with && and is_a?" do
    code = <<-CRYSTAL
      def call(x : String | Nil)
        if x && x.is_a?(String)
          x
        end
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover_and_isa.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "x", 3)
      pos = position_for(code, index)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("x : String")
      value.should_not contain("Nil")
    end
  end

  it "narrows type in case/when with type pattern" do
    code = <<-CRYSTAL
      def call(x : String | Int32)
        case x
        when String
          x
        end
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover_case_when.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "x", 2)
      pos = position_for(code, index)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("x : String")
      value.should_not contain("Int32")
    end
  end

  it "shows inferred type for block parameter from chained method call" do
    code = <<-CRYSTAL
      class MessageBuilder
        def self.generate(host : String) : Array(String)
        end
      end

      def call
        MessageBuilder.generate("localhost").map do |message|
          message
        end
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover_chained_block.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "message", 1)
      pos = position_for(code, index)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("message : String")
    end
  end

  it "infers return type of map from block body" do
    code = <<-CRYSTAL
      class Array(T)
        def map(& : T -> U) : Array(U) forall U
        end
      end

      class Builder
        def self.generate(host : String) : Array(String)
        end

        def self.package(msg : String) : Int32
        end
      end

      def call
        packages = Builder.generate("localhost").map { |msg| Builder.package(msg) }
        packages
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover_map_return.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "packages", 1)
      pos = position_for(code, index)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("packages : Array(Int32)")
    end
  end

  it "narrows type after early return with is_a? check" do
    code = <<-CRYSTAL
      class Slice(T)
      end

      def call(ip : Slice(UInt16) | Slice(UInt8))
        return ip if ip.is_a?(Slice(UInt8))
        ip
      end
    CRYSTAL

    with_tmpdir do |dir|
      path = File.join(dir, "hover_early_return.cr")
      File.write(path, code)

      ws = workspace_for(dir)

      uri = "file://#{path}"
      index = index_for(code, "ip", 3)
      pos = position_for(code, index)
      request = hover_request(uri, pos)
      hover = ws.hover(request)

      hover.should_not be_nil
      value = hover.not_nil!.contents.as_h["value"].as_s
      value.should contain("ip : Slice(UInt16)")
      value.should_not contain("UInt8")
    end
  end
end
