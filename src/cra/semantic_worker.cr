require "json"
require "fiber/execution_context"
require "compiler/crystal/syntax"

{% unless flag?(:execution_context) %}
  {% raise "Compile with -Dexecution_context to enable semantic worker" %}
{% end %}

module CRA
  module Semantic
    # Location information for symbols/diagnostics.
    struct Location
      include JSON::Serializable

      getter line : Int32
      getter column : Int32
      getter end_line : Int32?
      getter end_column : Int32?

      def initialize(@line : Int32, @column : Int32, @end_line : Int32? = nil, @end_column : Int32? = nil)
      end
    end

    # Minimal symbol info surfaced by the semantic worker.
    struct SymbolInfo
      include JSON::Serializable

      getter name : String
      getter kind : String
      getter container : Array(String)
      getter location : Location?
      getter signature : String?
      getter doc : String?

      def initialize(
        @name : String,
        @kind : String,
        @container : Array(String) = [] of String,
        @location : Location? = nil,
        @signature : String? = nil,
        @doc : String? = nil,
      )
      end
    end

    # Occurrence information used for references/highlights.
    struct Occurrence
      include JSON::Serializable

      getter name : String
      getter kind : String
      getter container : Array(String)
      getter location : Location?
      getter role : String

      def initialize(@name : String, @kind : String, @container : Array(String) = [] of String, @location : Location? = nil, @role : String = "ref")
      end
    end

    # Require edges for building the import graph.
    struct RequireEdge
      include JSON::Serializable

      getter target : String
      getter location : Location?

      def initialize(@target : String, @location : Location? = nil)
      end
    end

    struct Diagnostic
      include JSON::Serializable

      getter message : String
      getter severity : String
      getter location : Location?

      def initialize(@message : String, @severity : String = "error", @location : Location? = nil)
      end
    end

    # Result bundle returned by the worker.
    struct Result
      include JSON::Serializable

      getter symbols : Array(SymbolInfo)
      getter occurrences : Array(Occurrence)
      getter requires : Array(RequireEdge)
      getter diagnostics : Array(Diagnostic)

      def initialize(@symbols : Array(SymbolInfo), @occurrences : Array(Occurrence), @requires : Array(RequireEdge), @diagnostics : Array(Diagnostic) = [] of Diagnostic)
      end
    end

    private struct Job
      getter path : String
      getter text : String
      getter reply : Channel(Result)

      def initialize(@path : String, @text : String, @reply : Channel(Result))
      end
    end

    # Simple worker that runs in a dedicated thread to mimic an isolated execution context.
    class Worker
      @context : Fiber::ExecutionContext::Parallel

      def initialize
        @jobs = Channel(Job).new
        @context = Fiber::ExecutionContext::Parallel.new("semantic-worker", 4)
        @context.spawn { run_loop }
      end

      def shutdown
        @jobs.close
      end

      # Submit work and block for the result.
      def symbols_for(path : String, text : String) : Result
        reply = Channel(Result).new
        @jobs.send(Job.new(path, text, reply))
        reply.receive
      rescue Channel::ClosedError
        # Fallback to inline extraction if the worker loop is down.
        build_result(path, text)
      end

      private def run_loop
        loop do
          job = @jobs.receive?
          break unless job
          begin
            job.reply.send(build_result(job.path, job.text))
          rescue
            job.reply.send(Result.new([] of SymbolInfo, [] of Occurrence, [] of RequireEdge, [] of Diagnostic))
          end
        end
      end

      private def build_result(path : String, text : String) : Result
        parser = Crystal::Parser.new(text)
        parser.filename = path
        ast = parser.parse

        symbols = [] of SymbolInfo
        occurrences = [] of Occurrence
        requires = [] of RequireEdge

        collect_symbols(ast, [] of String, symbols, occurrences, requires)
        Result.new(symbols, occurrences, requires, [] of Diagnostic)
      rescue ex : Crystal::SyntaxException
        line = ex.line_number || 0
        column = ex.column_number || 0
        Result.new([] of SymbolInfo, [] of Occurrence, [] of RequireEdge, [Diagnostic.new(ex.message.to_s, "error", Location.new(line, column))])
      rescue
        Result.new([] of SymbolInfo, [] of Occurrence, [] of RequireEdge, [] of Diagnostic)
      end

      private def collect_symbols(node : Crystal::ASTNode?, container : Array(String), symbols : Array(SymbolInfo), occurrences : Array(Occurrence), requires : Array(RequireEdge))
        return unless node

        case node
        when Crystal::Expressions
          node.expressions.each { |child| collect_symbols(child, container, symbols, occurrences, requires) }
        when Crystal::EnumDef
          name = node.name.to_s
          loc = node.location
          loc_obj = loc && Location.new(loc.line_number, loc.column_number)
          symbols << SymbolInfo.new(name, node.class.name.split("::").last, container, loc_obj, signature_for(node), doc_for(node))
          occurrences << Occurrence.new(name, node.class.name.split("::").last, container, loc_obj, "def")
        when Crystal::ClassDef, Crystal::ModuleDef
          name = node.name.to_s
          loc = node.location
          loc_obj = loc && Location.new(loc.line_number, loc.column_number)
          symbols << SymbolInfo.new(name, node.class.name.split("::").last, container, loc_obj, signature_for(node), doc_for(node))
          occurrences << Occurrence.new(name, node.class.name.split("::").last, container, loc_obj, "def")
          child_container = container + [name]
          node.body.try { |body| collect_symbols(body, child_container, symbols, occurrences, requires) }
        when Crystal::Def
          name = node.name
          loc = node.location
          loc_obj = loc && Location.new(loc.line_number, loc.column_number)
          symbols << SymbolInfo.new(name, "Def", container, loc_obj, signature_for(node), doc_for(node))
          occurrences << Occurrence.new(name, "Def", container, loc_obj, "def")
          node.body.try { |body| collect_symbols(body, container, symbols, occurrences, requires) }
        when Crystal::Macro
          name = node.name
          loc = node.location
          loc_obj = loc && Location.new(loc.line_number, loc.column_number)
          symbols << SymbolInfo.new(name, "Macro", container, loc_obj, signature_for(node), doc_for(node))
          occurrences << Occurrence.new(name, "Macro", container, loc_obj, "def")
        when Crystal::Call
          name = node.name
          loc = node.location
          loc_obj = loc && Location.new(loc.line_number, loc.column_number)
          occurrences << Occurrence.new(name, "Call", container, loc_obj, "ref")
        when Crystal::Path
          name = node.names.join("::")
          loc = node.location
          loc_obj = loc && Location.new(loc.line_number, loc.column_number)
          occurrences << Occurrence.new(name, "Path", container, loc_obj, "ref")
        when Crystal::Assign
          name = assign_target_name(node)
          if name
            loc = node.location
            loc_obj = loc && Location.new(loc.line_number, loc.column_number)
            occurrences << Occurrence.new(name, "Assign", container, loc_obj, "write")
          end
        when Crystal::Require
          target = node.string
          loc = node.location
          loc_obj = loc && Location.new(loc.line_number, loc.column_number)
          requires << RequireEdge.new(target, loc_obj)
        else
          # no-op for other nodes
        end

        if node.responds_to?(:each_child)
          node.each_child do |child|
            collect_symbols(child, container, symbols, occurrences, requires)
          end
        end
      end

      private def signature_for(node)
        case node
        when Crystal::Def
          args = node.args.map(&.name).join(", ")
          suffix = node.return_type ? " : #{node.return_type}" : ""
          "def #{node.name}(#{args})#{suffix}"
        when Crystal::Macro
          args = node.args.map(&.name).join(", ")
          "macro #{node.name}(#{args})"
        when Crystal::ClassDef
          "class #{node.name}"
        when Crystal::ModuleDef
          "module #{node.name}"
        when Crystal::EnumDef
          "enum #{node.name}"
        else
          nil
        end
      end

      private def doc_for(node)
        node.responds_to?(:doc) ? node.doc : nil
      rescue
        nil
      end

      private def assign_target_name(node)
        target = node.target
        case target
        when Crystal::Var
          target.name
        when Crystal::InstanceVar
          target.name
        when Crystal::ClassVar
          target.name
        when Crystal::Path
          target.names.join("::")
        else
          nil
        end
      end
    end
  end
end
