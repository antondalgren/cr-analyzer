require "spec"
require "file_utils"

def with_tmpdir(&block)
  path = File.join(Dir.tempdir, "cra-spec-#{Time.utc.to_unix_ms}-#{Random.rand(1_000_000)}")
  FileUtils.mkdir_p(path)
  begin
    yield path
  ensure
    FileUtils.rm_rf(path)
  end
end
