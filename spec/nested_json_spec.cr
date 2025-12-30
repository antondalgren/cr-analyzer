require "spec"
require "../src/cra/types"

describe "JSON::Serializable with nested fields" do
  describe "deserialization" do
    it "parses nested fields correctly" do
      json_string = %({
        "id": "test-id-123",
        "params": {
          "capabilities": {},
          "processId": null,
          "rootPath": null,
          "rootUri": "file:///home/user/project",
          "workspaceFolders": null
        },
        "method": "initialize",
        "jsonrpc": "2.0"
      })

      request = CRA::Types::Request.from_json(json_string)
      request.should be_a(CRA::Types::InitializeRequest)

      init_request = request.as(CRA::Types::InitializeRequest)
      init_request.method.should eq("initialize")
      init_request.id.should eq("test-id-123")
      init_request.jsonrpc.should eq("2.0")
      init_request.root_uri.should eq("file:///home/user/project")
      init_request.process_id.should be_nil
      init_request.root_path.should be_nil
      init_request.workspace_folders.should be_nil
      init_request.capabilities.should be_a(CRA::Types::ClientCapabilities)
    end

    it "handles nil nested object" do
      json_string = %({
        "id": "test-id-456",
        "params": null,
        "method": "initialize",
        "jsonrpc": "2.0"
      })

      request = CRA::Types::Request.from_json(json_string)
      request.should be_a(CRA::Types::InitializeRequest)

      init_request = request.as(CRA::Types::InitializeRequest)
      init_request.root_uri.should be_nil
      init_request.capabilities.should be_nil
    end

    it "handles nested object with non-null processId" do
      json_string = %({
        "id": "test-id-789",
        "params": {
          "capabilities": {},
          "processId": 12345,
          "rootUri": "file:///test"
        },
        "method": "initialize",
        "jsonrpc": "2.0"
      })

      request = CRA::Types::Request.from_json(json_string)
      init_request = request.as(CRA::Types::InitializeRequest)

      init_request.process_id.should eq(12345)
      init_request.root_uri.should eq("file:///test")
    end
  end

  describe "serialization" do
    it "serializes nested fields back to nested object" do
      json_string = %({
        "id": "original-id",
        "params": {
          "capabilities": {},
          "processId": 999,
          "rootPath": "/some/path",
          "rootUri": "file:///original/path",
          "workspaceFolders": null
        },
        "method": "initialize",
        "jsonrpc": "2.0"
      })

      # Parse
      original = CRA::Types::Request.from_json(json_string).as(CRA::Types::InitializeRequest)

      # Serialize
      serialized = original.to_json

      # Parse again
      reparsed = CRA::Types::Request.from_json(serialized).as(CRA::Types::InitializeRequest)

      # Verify
      reparsed.method.should eq("initialize")
      reparsed.id.should eq("original-id")
      reparsed.root_uri.should eq("file:///original/path")
      reparsed.root_path.should eq("/some/path")
      reparsed.process_id.should eq(999)
    end

    it "serializes with nested object present in output" do
      json_string = %({
        "id": "test",
        "params": {
          "rootUri": "file:///test"
        },
        "method": "initialize",
        "jsonrpc": "2.0"
      })

      request = CRA::Types::Request.from_json(json_string).as(CRA::Types::InitializeRequest)
      serialized = request.to_json

      # Check that params key exists in serialized JSON
      serialized.should contain("\"params\"")
      serialized.should contain("\"rootUri\"")
      serialized.should contain("file:///test")
    end

    it "performs round-trip correctly" do
      original_json = %({
        "id": "round-trip-test",
        "params": {
          "capabilities": {},
          "rootUri": "file:///roundtrip"
        },
        "method": "initialize",
        "jsonrpc": "2.0"
      })

      # First parse
      first_parse = CRA::Types::Request.from_json(original_json).as(CRA::Types::InitializeRequest)

      # Serialize
      serialized = first_parse.to_json

      # Second parse
      second_parse = CRA::Types::Request.from_json(serialized).as(CRA::Types::InitializeRequest)

      # Third serialize
      second_serialized = second_parse.to_json

      # Parse both serialized versions - they should be equivalent
      final_first = CRA::Types::Request.from_json(serialized).as(CRA::Types::InitializeRequest)
      final_second = CRA::Types::Request.from_json(second_serialized).as(CRA::Types::InitializeRequest)

      final_first.root_uri.should eq(final_second.root_uri)
      final_first.method.should eq(final_second.method)
      final_first.id.should eq(final_second.id)
    end
  end

  describe "mixed properties" do
    it "handles both nested and non-nested properties" do
      json_string = %({
        "id": "mixed-test",
        "params": {
          "rootUri": "file:///nested/property"
        },
        "method": "initialize",
        "jsonrpc": "2.0"
      })

      request = CRA::Types::Request.from_json(json_string).as(CRA::Types::InitializeRequest)

      # Non-nested properties
      request.method.should eq("initialize")
      request.jsonrpc.should eq("2.0")
      request.id.should eq("mixed-test")

      # Nested property
      request.root_uri.should eq("file:///nested/property")
    end
  end
end
