require "socket"
require "http"
require "json"
require "./cra/types"

module CRA
  VERSION = "0.1.0"

  module JsonRPC
    class RPCRequest
      def self.from_io(io)
        request : Types::Request? = nil
        HTTP.parse_headers_and_body(io) do |headers, body|
          request = Types::Request.from_json(body) if body
        end
        raise "Invalid request" unless request
        new(request)
      end

      def initialize(@payload : Types::Request)
      end

      def inspect
        "#<#{self.class}: #{@jsonrpc}, #{@id}, #{@method}>"
      end
    end

    class Server
      Log = ::Log.for("jsonrpc.server")

      @sockets = [] of Socket::Server
      @listening = false

      def bind(server : Socket::Server)
        @sockets << server
        puts "Server bound to #{server}"
      end

      def listen
        @listening = true

        done = Channel(Nil).new

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
        @sockets.size.times { done.receive }
      end
    end
  end
end

server = CRA::JsonRPC::Server.new
server.bind(TCPServer.new("127.0.0.1", 9998))
server.listen
