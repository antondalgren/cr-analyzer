require "spec"
require "file_utils"
require "time"
require "../src/cra/workspace"

describe CRA::WorkspaceService do
  it "indexes workspace and exposes workspace symbols" do
    with_tmpdir do |root|
      File.write(File.join(root, "foo.cr"), "class Foo\nend\n")
      config = CRA::Indexer::Config.new(root_path: root, include_stdlib: false, warm_caches: true)

      service = CRA::WorkspaceService.new
      result = service.index_workspace(config)

      result.indexed_files.should eq(1)
      symbols = service.workspace_symbols.values.flat_map(&.symbols.map(&.name))
      symbols.should contain("Foo")
    end
  end

  it "reuses persisted symbol index for unchanged files" do
    with_tmpdir do |root|
      file = File.join(root, "foo.cr")
      File.write(file, "class Foo\nend\n")

      config = CRA::Indexer::Config.new(root_path: root, include_stdlib: false, warm_caches: true)
      db_config = CRA::Salsa::Config.new(root_path: root, persist_symbols: true)

      service = CRA::WorkspaceService.new(CRA::Salsa::Database.new(db_config))
      service.index_workspace(config)

      # Simulate a fresh process using the on-disk cache.
      db = CRA::Salsa::Database.new(db_config)
      db.reset_counters
      service = CRA::WorkspaceService.new(db)
      service.index_workspace(config)

      db.symbol_index_calls.should eq(0)
      symbols = service.workspace_symbols.values.flat_map(&.symbols.map(&.name))
      symbols.should contain("Foo")
    end
  end

  it "reindexes files when versions change" do
    with_tmpdir do |root|
      file = File.join(root, "foo.cr")
      File.write(file, "class Foo\nend\n")

      config = CRA::Indexer::Config.new(root_path: root, include_stdlib: false, warm_caches: true)
      db_config = CRA::Salsa::Config.new(root_path: root, persist_symbols: true)

      service = CRA::WorkspaceService.new(CRA::Salsa::Database.new(db_config))
      service.index_workspace(config)

      sleep 1.seconds
      File.write(file, "class Foo\nend\nclass Bar\nend\n")

      db = CRA::Salsa::Database.new(db_config)
      service = CRA::WorkspaceService.new(db)
      service.index_workspace(config)

      db.symbol_index_calls.should eq(1)
      symbols = service.workspace_symbols.values.flat_map(&.symbols.map(&.name))
      symbols.should contain("Bar")
    end
  end

  it "captures occurrences and require edges" do
    with_tmpdir do |root|
      file = File.join(root, "foo.cr")
      File.write(file, "require \"bar\"\nclass Foo\n def run; helper\n end\nend\n")

      config = CRA::Indexer::Config.new(root_path: root, include_stdlib: false, warm_caches: true)
      db_config = CRA::Salsa::Config.new(root_path: root, persist_symbols: true)

      service = CRA::WorkspaceService.new(CRA::Salsa::Database.new(db_config))
      service.index_workspace(config)

      fid = service.workspace_symbols.keys.first
      occs = service.occurrence_index(fid).occurrences
      reqs = service.require_index(fid).requires

      occs.any? { |o| o.name == "run" && o.role == "def" }.should be_true
      occs.any? { |o| o.role == "ref" }.should be_true
      reqs.any? { |r| r.target == "bar" }.should be_true
    end
  end
end
