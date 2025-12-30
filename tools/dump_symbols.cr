#!/usr/bin/env crystal
# Usage: crystal run tools/dump_symbols.cr -Dpreview_mt -Dexecution_context -- [--root PATH] [--no-stdlib] [--verbose]
# Requires compilation flags: -Dpreview_mt -Dexecution_context so that the semantic worker runs in a parallel execution context.

require "option_parser"
require "json"
require "time"

require "../src/cra/workspace"
require "../src/cra/indexer"

root = Dir.current
include_stdlib = true
verbose = false

OptionParser.parse do |parser|
  parser.banner = "Dump workspace symbols as JSON"
  parser.on("--root PATH", "Workspace root (default: current dir)") { |path| root = File.expand_path(path) }
  parser.on("--no-stdlib", "Skip Crystal stdlib indexing") { include_stdlib = false }
  parser.on("--verbose", "Print progress to stderr") { verbose = true }
  parser.on("-h", "--help", "Show help") do
    puts parser
    exit
  end
end

config = CRA::Indexer::Config.new(root_path: root, include_stdlib: include_stdlib, warm_caches: true)
db_config = CRA::Salsa::Config.new(root_path: root, persist_symbols: true)
db = CRA::Salsa::Database.new(db_config)
service = CRA::WorkspaceService.new(db)

progress_cb = if verbose
                ->(report : CRA::Indexer::ProgressReport) do
                  STDERR.puts "[#{report.phase}] #{report.indexed_files}/#{report.total_files} #{report.current_path}"
                end
              else
                nil
              end

start = Time.monotonic
result = progress_cb ? service.index_workspace(config, &progress_cb) : service.index_workspace(config)
index_ms = (Time.monotonic - start).total_milliseconds

symbols = service.workspace_symbols
flat = [] of Hash(String, JSON::Any)

symbols.each do |file_id, idx|
  idx.symbols.each do |sym|
    loc = sym.location
    flat << {
      "file_id"   => JSON::Any.new(file_id.path),
      "name"      => JSON::Any.new(sym.name),
      "kind"      => JSON::Any.new(sym.kind),
      "container" => JSON.parse(sym.container.to_json),
      "line"      => loc ? JSON::Any.new(loc.line) : JSON::Any.new(nil),
      "column"    => loc ? JSON::Any.new(loc.column) : JSON::Any.new(nil),
    }
  end
end

output = JSON.build do |json|
  json.object do
    json.field "root", root
    json.field "include_stdlib", include_stdlib
    json.field "indexed_files", result.indexed_files
    json.field "skipped_files", result.skipped_files
    json.field "failed_files", result.failed_files
    json.field "errors" do
      json.array do
        result.errors.each { |err| json.string err }
      end
    end
    json.field "symbols" do
      json.array do
        flat.each do |sym|
          json.object do
            json.field "file_id", sym["file_id"].as_s
            json.field "name", sym["name"].as_s
            json.field "kind", sym["kind"].as_s
            json.field "container" do
              json.array do
                sym["container"].as_a.each { |c| json.string c.as_s }
              end
            end
            json.field "line", sym["line"].raw
            json.field "column", sym["column"].raw
          end
        end
      end
    end
    json.field "timings_ms" do
      json.object do
        json.field "index", index_ms
      end
    end
  end
end

puts output
