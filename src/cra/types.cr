require "json"
require "./nested_json"

module CRA
  module Types
    abstract class Message
      include JSON::Serializable
    end

    abstract class Request
      include JSON::Serializable

      property method : String
      property jsonrpc : String = "2.0"
      property id : String | Int32

      use_json_discriminator "method", {"initialize" => InitializeRequest}
    end

    class Response < Message
      getter id : String | Int32

      def initialize(@id : String | Int32)
      end
    end

    class Notification < Message
      getter method : String

      def initialize(@method : String)
      end
    end

    class ResponseError < Message
      getter code : Int32
      getter message : String
    end

    module ErrorCodes
      ERROR_CODE_INVALID_REQUEST  = -32600
      ERROR_CODE_METHOD_NOT_FOUND = -32601
      ERROR_CODE_INVALID_PARAMS   = -32602
      ERROR_CODE_INTERNAL_ERROR   = -32603
      ERROR_CODE_SERVER_ERROR     = -32000..-32099
      ERROR_CODE_SERVER_ERROR_MIN = -32000
      ERROR_CODE_SERVER_ERROR_MAX = -32099
      ERROR_CODE_PARSE_ERROR      = -32700
    end

    class WorkspaceClientCapabilities
      include JSON::Serializable

      getter apply_edit : Bool?
      getter workspace_edit : Bool?
      getter did_change_watched_files : Bool?
      getter did_change_configuration : Bool?
      getter did_change_workspace_folders : Bool?
    end

    class TextDocumentClientCapabilities
      include JSON::Serializable

      getter synchronization : Bool?
      getter completion : Bool?
      getter hover : Bool?
      getter signature_help : Bool?
      getter references : Bool?
      getter document_highlight : Bool?
      getter document_symbol : Bool?
      getter code_action : Bool?
      getter code_lens : Bool?
      getter document_formatting : Bool?
      getter document_range_formatting : Bool?
      getter document_on_type_formatting : Bool?
      getter rename : Bool?
      getter document_link : Bool?
      getter color_provider : Bool?
      getter folding_range : Bool?
      getter selection_range : Bool?
      getter call_hierarchy : Bool?
      getter semantic_tokens : Bool?
      getter linked_editing_range : Bool?
      getter moniker : Bool?
    end

    class ClientCapabilities
      include JSON::Serializable

      getter workspace : WorkspaceClientCapabilities?
      getter text_document : TextDocumentClientCapabilities?
    end

    class InitializeRequest < Request
      @[JSON::Field(nested: "params", key: "capabilities")]
      property capabilities : ClientCapabilities?

      @[JSON::Field(nested: "params", key: "processId")]
      property process_id : Int32?

      @[JSON::Field(nested: "params", key: "rootPath")]
      property root_path : String?

      @[JSON::Field(nested: "params", key: "rootUri")]
      property root_uri : String?

      @[JSON::Field(nested: "params", key: "workspaceFolders")]
      property workspace_folders : Array(String)?
    end
  end
end
