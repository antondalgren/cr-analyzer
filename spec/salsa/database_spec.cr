require "spec"
require "dir"
require "../../src/cra/salsa"

describe CRA::Salsa::Database do
  it "caches parsed documents until the input changes" do
    config = CRA::Salsa::Config.new(persist_symbols: false)
    db = CRA::Salsa::Database.new(config)
    fid = CRA::Salsa::FileId.new("src/foo.cr")

    db.write_file(fid, "class Foo\nend\n", 1)
    doc1 = db.parsed_document(fid)
    doc2 = db.parsed_document(fid)

    doc1.should be(doc2)
    db.parse_calls.should eq(1)

    db.write_file(fid, "class Foo\nend\nFoo.new\n", 2)
    doc3 = db.parsed_document(fid)

    doc3.should_not be(doc2)
    db.parse_calls.should eq(2)
  end

  it "reuses cached symbol indexes and invalidates them on file changes" do
    db = CRA::Salsa::Database.new
    fid = CRA::Salsa::FileId.new("lib/bar.cr")

    db.write_file(fid, "module Bar\n CONST = 1\nend\n", 5)
    idx1 = db.symbol_index(fid)
    idx2 = db.symbol_index(fid)

    idx1.should be(idx2)
    db.symbol_index_calls.should eq(1)

    db.write_file(fid, "module Bar\n CONST = 2\n def self.call; end\nend\n", 6)
    idx3 = db.symbol_index(fid)

    idx3.should_not be(idx2)
    db.symbol_index_calls.should eq(2)
  end

  it "caches workspace symbols until any file cache is invalidated" do
    db = CRA::Salsa::Database.new
    a = CRA::Salsa::FileId.new("src/a.cr")
    b = CRA::Salsa::FileId.new("src/b.cr")

    db.write_file(a, "class A\nend\n", 1)
    db.write_file(b, "class B\nend\n", 1)

    first = db.workspace_symbols
    first.should be_a(Hash(CRA::Salsa::FileId, CRA::Salsa::SymbolIndex))
    db.workspace_symbols_calls.should eq(1)

    db.workspace_symbols
    db.workspace_symbols_calls.should eq(1)

    db.write_file(a, "class A\n def run; end\nend\n", 2)
    db.workspace_symbols
    db.workspace_symbols_calls.should eq(2)
  end

  it "reports cache sizes and supports clearing them" do
    db = CRA::Salsa::Database.new

    fid = CRA::Salsa::FileId.new("src/cache.cr")

    db.write_file(fid, "class Cache\nend\n", 1)

    db.cache_snapshot["parsed_cache"].should eq(0)

    db.cache_snapshot["symbol_cache"].should eq(0)

    db.parsed_document(fid)

    db.symbol_index(fid)

    snapshot = db.cache_snapshot

    snapshot["parsed_cache"].should eq(1)

    snapshot["symbol_cache"].should eq(1)

    snapshot["workspace_symbols_cached"].should eq(0)

    db.workspace_symbols

    db.cache_snapshot["workspace_symbols_cached"].should eq(1)

    db.clear_caches

    cleared = db.cache_snapshot

    cleared["parsed_cache"].should eq(0)

    cleared["symbol_cache"].should eq(0)

    cleared["workspace_symbols_cached"].should eq(0)
  end

  it "persists and reloads symbol indexes from disk when configured" do
    with_tmpdir do |tmp|
      config = CRA::Salsa::Config.new(index_directory: tmp, persist_symbols: true, max_in_memory_symbols: 0)
      db = CRA::Salsa::Database.new(config)
      fid = CRA::Salsa::FileId.new("src/persist.cr")

      db.write_file(fid, "module Persist\n CONST = 1\nend\n", 1)
      db.symbol_index(fid)
      db.clear_caches
      db.reset_counters

      db.symbol_index(fid)

      db.parse_calls.should eq(0)
      db.symbol_index_calls.should eq(0)
    end
  end

  it "resets counters and raises MissingInputError for unread files" do
    config = CRA::Salsa::Config.new(persist_symbols: false)
    db = CRA::Salsa::Database.new(config)
    fid = CRA::Salsa::FileId.new("missing.cr")

    expect_raises(CRA::Salsa::MissingInputError) { db.read_file(fid) }

    db.write_file(fid, "struct Missing; end\n", 1)
    db.parsed_document(fid)
    db.symbol_index(fid)
    db.workspace_symbols

    db.parse_calls.should eq(1)
    db.symbol_index_calls.should eq(1)
    db.workspace_symbols_calls.should eq(1)

    db.reset_counters
    db.parse_calls.should eq(0)
    db.symbol_index_calls.should eq(0)
    db.workspace_symbols_calls.should eq(0)
  end

  it "invalidates cached queries when unrelated files change and supports removals" do
    db = CRA::Salsa::Database.new
    a = CRA::Salsa::FileId.new("src/a.cr")
    b = CRA::Salsa::FileId.new("src/b.cr")

    db.write_file(a, "class A\nend\n", 1)
    db.write_file(b, "class B\nend\n", 1)

    first = db.symbol_index(a)
    db.symbol_index_calls.should eq(1)

    db.write_file(b, "class B\n def run; end\nend\n", 2)
    second = db.symbol_index(a)
    db.symbol_index_calls.should eq(1)
    second.should be(first)

    db.remove_file(a).should be_true
    expect_raises(CRA::Salsa::MissingInputError) { db.symbol_index(a) }
  end
end
