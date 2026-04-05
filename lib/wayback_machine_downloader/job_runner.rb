require 'json'
require 'thread'
require 'uri'

require_relative '../wayback_machine_downloader'
require_relative 'archive_builder'
require_relative 'job_store'
require_relative 'post_processor'

class WaybackMachineDownloaderJobRunner
  DEFAULT_WORKER_COUNT = 2

  def initialize(job_store, worker_count = DEFAULT_WORKER_COUNT)
    @job_store = job_store
    @worker_count = worker_count.to_i > 0 ? worker_count.to_i : DEFAULT_WORKER_COUNT
    @queue = Queue.new
    @workers = []
    @worker_count.times do
      @workers << Thread.new { work_loop }
    end
  end

  def enqueue(job_id)
    @queue << job_id
  end

  private

  def work_loop
    loop do
      job_id = @queue.pop
      break if job_id == :shutdown

      run_job job_id
    end
  end

  def run_job(job_id)
    @job_store.mark_running job_id
    job = @job_store.fetch_job(job_id)
    options = symbolize_keys(job['options'])

    downloader = WaybackMachineDownloader.new(
      options.merge(
        directory: job['output_path'],
        logger: proc { |message| @job_store.append_log_message(job_id, message) },
        event_callback: proc { |event| @job_store.record_event(job_id, event) }
      )
    )

    if options[:list]
      handle_list_job job_id, job, downloader
    else
      handle_download_job job_id, job, downloader
    end
  rescue StandardError => e
    @job_store.mark_failed job_id, "#{e.class}: #{e.message}"
  end

  def handle_list_job(job_id, job, downloader)
    files = downloader.list_files_data
    artifact_path = File.join(File.dirname(job['output_path']), 'snapshots.json')

    File.open(artifact_path, 'wb') do |file|
      file.write JSON.pretty_generate(files)
    end

    @job_store.mark_finished job_id, {
      'status' => 'completed',
      'files_total' => files.length,
      'artifact_path' => artifact_path,
      'artifact_name' => artifact_filename(job['options']['base_url'], 'snapshots.json'),
      'artifact_content_type' => 'application/json',
      'artifact_size_bytes' => File.size(artifact_path)
    }
  end

  def handle_download_job(job_id, job, downloader)
    summary = downloader.download_files
    result = {
      'status' => summary[:status].to_s,
      'files_total' => summary[:files_total]
    }
    result['duration_seconds'] = summary[:duration_seconds] if summary[:duration_seconds]

    if summary[:status].to_s == 'completed'
      run_post_processing(job_id, job)
      @job_store.append_log_message job_id, 'Packaging downloaded files into an archive'
      artifact_path = WaybackMachineDownloaderArchiveBuilder.new(
        job['output_path'],
        job['archive_path'],
        root_directory_name: safe_slug(job['options']['base_url'])
      ).build

      result['artifact_path'] = artifact_path
      result['artifact_name'] = artifact_filename(job['options']['base_url'], 'archive.tar.gz')
      result['artifact_content_type'] = 'application/gzip'
      result['artifact_size_bytes'] = File.size(artifact_path)
    end

    @job_store.mark_finished job_id, result
  end

  def run_post_processing(job_id, job)
    options = symbolize_keys(job['options'])
    return unless options[:rewrite_links] || options[:clean_html]

    @job_store.append_log_message job_id, 'Running post-processing on downloaded files'
    summary = WaybackMachineDownloaderPostProcessor.new(
      job['output_path'],
      job['options']['base_url'],
      rewrite_links: options[:rewrite_links],
      clean_html: options[:clean_html],
      logger: proc { |message| @job_store.append_log_message(job_id, message) }
    ).run

    @job_store.append_log_message(
      job_id,
      "Post-processing complete: #{summary[:rewritten_files]} rewritten, #{summary[:cleaned_files]} cleaned, #{summary[:renamed_paths]} renamed"
    )
  end

  def symbolize_keys(hash)
    hash.each_with_object({}) do |(key, value), memo|
      memo[key.to_sym] = value
    end
  end

  def artifact_filename(base_url, suffix)
    "#{safe_slug(base_url)}-#{suffix}"
  end

  def safe_slug(base_url)
    uri = URI.parse(base_url) rescue nil
    source = uri && uri.host ? uri.host : base_url
    slug = source.to_s.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/\A-+|-+\z/, '')
    slug.empty? ? 'wayback-download' : slug
  end
end
