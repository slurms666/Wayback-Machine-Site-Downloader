require 'fileutils'
require 'tmpdir'
require 'minitest/autorun'

require_relative '../lib/wayback_machine_downloader/job_store'

class WaybackMachineDownloaderJobStoreTest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @store = WaybackMachineDownloaderJobStore.new(@tmpdir)
  end

  def teardown
    FileUtils.rm_rf @tmpdir
  end

  def test_create_job_persists_metadata
    job = @store.create_job('base_url' => 'http://example.com')
    fetched_job = @store.fetch_job(job['id'])

    assert_equal 'queued', fetched_job['status']
    assert_equal 'http://example.com', fetched_job['options']['base_url']
    assert_equal 0, fetched_job['progress']['files_processed']
  end

  def test_record_event_updates_progress
    job = @store.create_job('base_url' => 'http://example.com')

    @store.record_event(job['id'], {
      type: 'file_processed',
      processed: 3,
      files_total: 10,
      file_url: 'http://example.com/index.html',
      status: 'downloaded'
    })

    fetched_job = @store.fetch_job(job['id'])
    assert_equal 3, fetched_job['progress']['files_processed']
    assert_equal 10, fetched_job['progress']['files_total']
    assert_equal 'http://example.com/index.html', fetched_job['progress']['current_file_url']
    assert_match(/Processed 3\/10/, fetched_job['progress']['last_message'])
  end

  def test_mark_finished_records_artifact
    job = @store.create_job('base_url' => 'http://example.com')

    @store.mark_finished(job['id'], {
      'status' => 'completed',
      'files_total' => 12,
      'artifact_name' => 'example.tar.gz',
      'artifact_size_bytes' => 2048
    })

    fetched_job = @store.fetch_job(job['id'])
    assert_equal 'completed', fetched_job['status']
    assert_equal 12, fetched_job['progress']['files_total']
    assert_equal 'example.tar.gz', fetched_job['artifact_name']
    assert_equal 2048, fetched_job['artifact_size_bytes']
  end
end
