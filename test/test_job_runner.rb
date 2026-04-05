require 'minitest/autorun'

require_relative '../lib/wayback_machine_downloader/job_runner'

class WaybackMachineDownloaderJobRunnerTest < Minitest::Test
  def test_job_runner_loads_downloader_class
    assert defined?(WaybackMachineDownloader)
  end
end
