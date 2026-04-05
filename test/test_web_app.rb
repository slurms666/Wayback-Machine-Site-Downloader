require 'fileutils'
require 'tmpdir'
require 'minitest/autorun'

require_relative '../lib/wayback_machine_downloader/job_store'
require_relative '../lib/wayback_machine_downloader/web_app'

class WaybackMachineDownloaderWebAppTest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @app = WaybackMachineDownloaderWebApp.new(
      root_path: File.expand_path('..', File.dirname(__FILE__)),
      storage_path: @tmpdir,
      job_store: WaybackMachineDownloaderJobStore.new(@tmpdir),
      job_runner: Object.new
    )
  end

  def teardown
    FileUtils.rm_rf @tmpdir
  end

  def test_sanitize_job_options_normalizes_and_clamps_values
    options = @app.send(:sanitize_job_options, {
      'base_url' => 'example.com',
      'threads_count' => '99',
      'maximum_pages' => '0',
      'list' => '1',
      'rewrite_links' => '1',
      'clean_html' => '1'
    })

    assert_equal 'http://example.com', options['base_url']
    assert_equal 8, options['threads_count']
    assert_equal 1, options['maximum_pages']
    assert_equal true, options['list']
    assert_equal true, options['rewrite_links']
    assert_equal true, options['clean_html']
  end

  def test_sanitize_job_options_rejects_bad_timestamps
    assert_raises(ArgumentError) do
      @app.send(:sanitize_job_options, {
        'base_url' => 'http://example.com',
        'from_timestamp' => 'not-a-timestamp'
      })
    end
  end
end
