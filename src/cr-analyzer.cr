require "socket"
require "http"
require "json"
require "./cra/types"
require "./cra/workspace"
require "log/io_backend"

module CRA
  VERSION = "0.1.0"

  module JsonRPC
    class Processor
      def initialize(@server : Server)
      end

      def process(request, output : IO)
        response : JSON::Serializable | Nil = handle(request)
        if response
          @server.send(response)
          @
        end
      end

      def handle(request : Types::Message)
        Log.warn { "Unhandled request type: #{request.class}" }
        Log.

        nil
      end

      def handle(request : Types::CompletionRequest)
        Log.error { "Handling completion request" }
        Types::Response.new(
          request.id,
          Types::CompletionList.new(
            is_incomplete: false,
            items: [Types::CompletionItem.new(label: "Test Completion")] of Types::CompletionItem))
      rescue ex
        Log.error { "Error handling request: #{ex.message}" }
        nil
      end

      def handle(request : Types::InitializedNotification)
        Log.info { "Client initialized" }
        nil
      end

      def handle(request : Types::InitializeRequest)
        Log.error { "Handling initialize request" }
        Types::Response.new(request.id, Types::InitializeResult.new(
          capabilities: Types::ServerCapabilities.new(
            document_symbol_provider: true,
            definition_provider: true,
            references_provider: true,
            workspace_symbol_provider: true,
            type_definition_provider: true,
            implementation_provider: true,
            document_formatting_provider: false,
            document_range_formatting_provider: false,
            rename_provider: true,
            completion_provider: Types::CompletionOptions.new(trigger_characters: [".", ":", "@", "#", "<", "\"", "'", "/", " "])
          )
        ))
      rescue ex
        Log.error { "Error handling request: #{ex.message}" }
        nil
      end
    end

    class RPCRequest
      getter payload : Types::Message
      def self.from_io(io)
        request : Types::Message? = nil
        HTTP.parse_headers_and_body(io) do |headers, body|
          request = Types::Message.from_json(body) if body
        end
        raise "Invalid request" unless request
        new(request)
      end

      def initialize(@payload : Types::Message)
      end

      def inspect
        "#<#{self.class}: #{@jsonrpc}, #{@id}, #{@method}>"
      end
    end

    class Server
      Log = ::Log.for("jsonrpc.server")

      @sockets = [] of Socket::Server
      @listening = false

      @input = STDIN
      @output = STDOUT

      def initialize(processor : Processor | Nil = nil)
        @sockets = [] of Socket::Server
        @listening = false
        @processor = processor || Processor.new(self)
      end

      def send(data)
        body = data.to_json
        @output.print "Content-Length: #{body.bytesize}\r\n"
        @output.print "\r\n"
        @output.print body
      ensure
        @output.flush
      end

      def bind(server : Socket::Server)
        @sockets << server
        puts "Server bound to #{server}"
      end

      def listen
        ::Log.setup(backend: ::Log::IOBackend.new(io: STDERR))
        @listening = true

        done = Channel(Nil).new

        spawn do
          input = STDIN
          output = STDOUT

          loop do
            request = RPCRequest.from_io(input)
            Log.info { "Received request: #{request}" }
            @processor.as(Processor).process(request.payload, output)
          rescue ex
            Log.error { "Error reading request from stdin: #{ex.message}" }
            break
          end
        ensure
          Log.info { "Shutting down stdin listener" }
          done.send(nil)
        end

        @sockets.each do |socket|
          spawn do
            loop do
              io = begin
                socket.accept?
              rescue ex
                Log.error { "Error accepting connection: #{ex.message}" }
                next
              end
              if io
                request = RPCRequest.from_io(io)
                Log.info { "Received request: #{request}" }
                io.close
              else
                Log.error { "Error accepting connection: #{io}" }
                break
              end
            end
          ensure
            done.send(nil)
          end
        end
        (@sockets.size + 1).times { done.receive }
      end
    end
  end
end


