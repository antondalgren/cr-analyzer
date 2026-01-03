require "./types"
require "uri"

module CRA
  class WorkspaceDocument < Types::TextDocumentItem
    property opened : Bool = false
  end

  class Workspace
    Log = ::Log.for("CRA::Workspace")

    def self.from_s(uri : String)
      new(URI.parse(uri))
    end

    def self.from_uri(uri : URI)
      new(uri)
    end

    getter root : URI

    def initialize(@root : URI)
    end

    def scan
      # Scan the workspace for Crystal files
      Log.info { "Scanning workspace at #{@root}" }
    end
  end
end
