require "spec"
require "file_utils"

WORKSPACE_CACHE = {} of String => CRA::Workspace

def with_tmpdir(&block)
  path = File.join(Dir.tempdir, "cra-spec-#{Time.utc.to_unix_ms}-#{Random.rand(1_000_000)}")
  FileUtils.mkdir_p(path)
  begin
    ENV["CRA_SKIP_STDLIB_SCAN"] = "1"
    yield path
  ensure
    FileUtils.rm_rf(path)
  end
end

def workspace_for(path : String) : CRA::Workspace
  WORKSPACE_CACHE[path] ||= begin
    ws = CRA::Workspace.from_s("file://#{path}")
    ws.scan
    ws
  end
end
