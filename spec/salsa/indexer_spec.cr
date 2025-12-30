require "spec"

require "dir"
require "file_utils"

require "../../src/cra/salsa"

require "../../src/cra/indexer"

describe CRA::Indexer::WorkspaceIndexer do
  it "indexes Crystal files respecting ignored and hidden directories" do
    with_tmpdir do |root|
      File.write(File.join(root, "app.cr"), "class App; end\n")
      FileUtils.mkdir_p(File.join(root, "src"))
      File.write(File.join(root, "src", "main.cr"), "module Main; end\n")
      File.write(File.join(root, "src", "ignore.txt"), "nothing to see here")
      FileUtils.mkdir_p(File.join(root, "ignored"))
      File.write(File.join(root, "ignored", "skip.cr"), "class Skip; end\n")
      FileUtils.mkdir_p(File.join(root, ".hidden"))
      File.write(File.join(root, ".hidden", "hidden.cr"), "class Hidden; end\n")

      db = CRA::Salsa::Database.new
      config = CRA::Indexer::Config.new(root_path: root, ignore_directories: {"ignored"}, include_stdlib: false)
      indexer = CRA::Indexer::WorkspaceIndexer.new(db, config)

      result = indexer.index!

      result.indexed_files.should eq(2)
      result.skipped_files.should eq(0)
      result.failed_files.should eq(0)
      result.errors.should be_empty

      db.read_file(CRA::Salsa::FileId.new("workspace:app.cr")).text.should eq("class App; end\n")
      db.read_file(CRA::Salsa::FileId.new("workspace:src/main.cr")).text.should eq("module Main; end\n")
      expect_raises(CRA::Salsa::MissingInputError) { db.read_file(CRA::Salsa::FileId.new("workspace:ignored/skip.cr")) }
    end
  end

  it "emits progress for each discovered Crystal file" do
    with_tmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "lib"))
      a = File.join(root, "lib", "a.cr")
      b = File.join(root, "lib", "b.cr")
      File.write(a, "class A; end\n")
      File.write(b, "class B; end\n")

      db = CRA::Salsa::Database.new
      config = CRA::Indexer::Config.new(root_path: root, include_stdlib: false)
      indexer = CRA::Indexer::WorkspaceIndexer.new(db, config)

      reports = [] of CRA::Indexer::ProgressReport
      result = indexer.index! ->(progress : CRA::Indexer::ProgressReport) { reports << progress }

      result.indexed_files.should eq(2)
      reports.size.should eq(2)
      reports.map(&.total_files).uniq.should eq([2])
      reported_paths = reports.map(&.current_path).to_set
      reported_paths.should eq({a, b}.to_set)
      reports.map(&.phase).uniq.should eq(["dependencies"])
    end
  end

  it "returns zero counts when no Crystal files are present" do
    with_tmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "docs"))
      File.write(File.join(root, "README.md"), "# Crystal Project\n")

      db = CRA::Salsa::Database.new
      config = CRA::Indexer::Config.new(root_path: root, include_stdlib: false)
      indexer = CRA::Indexer::WorkspaceIndexer.new(db, config)

      result = indexer.index!

      result.indexed_files.should eq(0)
      result.skipped_files.should eq(0)
      result.failed_files.should eq(0)
      result.errors.should be_empty
      db.cache_snapshot["parsed_cache"].should eq(0)
    end
  end

  it "warms caches when configured" do
    with_tmpdir do |root|
      File.write(File.join(root, "foo.cr"), "class Foo; end\n")

      db = CRA::Salsa::Database.new
      config = CRA::Indexer::Config.new(root_path: root, include_stdlib: false, warm_caches: true)
      indexer = CRA::Indexer::WorkspaceIndexer.new(db, config)

      indexer.index!

      db.parse_calls.should eq(1)
      db.symbol_index_calls.should eq(1)
    end
  end

  it "indexes dependency files with distinct labels" do
    with_tmpdir do |root|
      dep_root = File.join(root, "lib", "foo", "src")
      FileUtils.mkdir_p(dep_root)
      File.write(File.join(dep_root, "foo.cr"), "module Foo; end\n")

      db = CRA::Salsa::Database.new
      config = CRA::Indexer::Config.new(root_path: root, dependency_roots: {"lib"}, include_stdlib: false)
      indexer = CRA::Indexer::WorkspaceIndexer.new(db, config)

      result = indexer.index!

      result.indexed_files.should eq(1)
      db.read_file(CRA::Salsa::FileId.new("dep:foo:src/foo.cr")).text.should eq("module Foo; end\n")
    end
  end
end
