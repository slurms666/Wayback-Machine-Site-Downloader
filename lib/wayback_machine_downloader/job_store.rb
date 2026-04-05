require 'fileutils'
require 'json'
require 'securerandom'
require 'thread'
require 'time'

class WaybackMachineDownloaderJobStore
  def initialize(storage_path)
    @storage_path = File.expand_path(storage_path)
    @jobs_path = File.join(@storage_path, 'jobs')
    @mutex = Mutex.new
    FileUtils.mkdir_p @jobs_path
  end

  def create_job(options)
    job = @mutex.synchronize do
      timestamp = timestamp_now
      id = SecureRandom.hex(10)
      job_directory = job_path(id)
      output_path = File.join(job_directory, 'output')
      archive_path = File.join(job_directory, 'download.tar.gz')

      FileUtils.mkdir_p output_path

      created_job = {
        'id' => id,
        'status' => 'queued',
        'created_at' => timestamp,
        'updated_at' => timestamp,
        'options' => options,
        'output_path' => output_path,
        'archive_path' => archive_path,
        'artifact_path' => nil,
        'artifact_name' => nil,
        'artifact_content_type' => nil,
        'artifact_size_bytes' => nil,
        'error_message' => nil,
        'progress' => {
          'snapshot_count' => 0,
          'files_total' => nil,
          'files_processed' => 0,
          'current_file_url' => nil,
          'last_error' => nil,
          'last_message' => 'Job queued'
        }
      }

      write_job created_job
      created_job
    end

    append_log_message job['id'], "Queued job for #{options['base_url']}"
    job
  end

  def fetch_job(id)
    @mutex.synchronize do
      read_job id
    end
  end

  def list_jobs(limit = 10)
    job_ids = Dir.glob(File.join(@jobs_path, '*')).select { |path| File.directory?(path) }.map { |path| File.basename(path) }
    jobs = job_ids.map { |job_id| fetch_job(job_id) }.compact
    jobs.sort_by { |job| job['created_at'] }.reverse.first(limit)
  end

  def mark_running(id)
    update_job(id) do |job|
      job['status'] = 'running'
      job['started_at'] = timestamp_now
      job['error_message'] = nil
      job['progress']['last_message'] = 'Job started'
    end
    append_log_message id, 'Job started'
  end

  def mark_finished(id, result = {})
    update_job(id) do |job|
      job['status'] = (result['status'] || 'completed').to_s
      job['finished_at'] = timestamp_now
      job['error_message'] = nil
      job['duration_seconds'] = result['duration_seconds'] if result.key?('duration_seconds')
      job['artifact_path'] = result['artifact_path'] if result['artifact_path']
      job['artifact_name'] = result['artifact_name'] if result['artifact_name']
      job['artifact_content_type'] = result['artifact_content_type'] if result['artifact_content_type']
      job['artifact_size_bytes'] = result['artifact_size_bytes'] if result['artifact_size_bytes']
      job['progress']['files_total'] = result['files_total'] if result.key?('files_total')
      job['progress']['last_message'] = final_message_for(job)
    end
    append_log_message id, 'Job finished'
  end

  def mark_failed(id, error_message)
    update_job(id) do |job|
      job['status'] = 'failed'
      job['finished_at'] = timestamp_now
      job['error_message'] = error_message
      job['progress']['last_message'] = error_message
    end
    append_log_message id, error_message
  end

  def record_event(id, event)
    normalized_event = stringify_keys(event)
    update_job(id) do |job|
      progress = job['progress']
      progress['snapshot_count'] = normalized_event['snapshot_count'] if normalized_event.key?('snapshot_count')
      progress['files_total'] = normalized_event['files_total'] if normalized_event.key?('files_total')
      progress['files_processed'] = normalized_event['processed'] if normalized_event.key?('processed')
      progress['current_file_url'] = normalized_event['file_url'] if normalized_event.key?('file_url')
      progress['last_error'] = normalized_event['error'] if normalized_event['error']
      progress['last_message'] = build_progress_message(normalized_event)
    end
    append_log_entry id, normalized_event
  end

  def append_log_message(id, message)
    append_log_entry id, {
      'type' => 'log',
      'timestamp' => timestamp_now,
      'message' => message.to_s
    }
  end

  def tail_log(id, line_count = 40)
    log_path = log_file_path(id)
    return [] unless File.exist?(log_path)

    File.readlines(log_path).last(line_count).map do |line|
      JSON.parse(line)
    rescue JSON::ParserError
      { 'type' => 'log', 'timestamp' => nil, 'message' => line.strip }
    end
  end

  private

  def update_job(id)
    @mutex.synchronize do
      job = read_job(id)
      raise ArgumentError, "Unknown job: #{id}" unless job

      yield job
      job['updated_at'] = timestamp_now
      write_job job
    end
  end

  def write_job(job)
    FileUtils.mkdir_p job_path(job['id'])
    File.open(job_file_path(job['id']), 'wb') do |file|
      file.write JSON.pretty_generate(job)
    end
  end

  def read_job(id)
    path = job_file_path(id)
    return nil unless File.exist?(path)

    JSON.parse(File.read(path))
  end

  def append_log_entry(id, entry)
    @mutex.synchronize do
      FileUtils.mkdir_p job_path(id)
      File.open(log_file_path(id), 'ab') do |file|
        file.write(JSON.generate(entry) + "\n")
      end
    end
  end

  def job_path(id)
    File.join(@jobs_path, id)
  end

  def job_file_path(id)
    File.join(job_path(id), 'job.json')
  end

  def log_file_path(id)
    File.join(job_path(id), 'events.ndjson')
  end

  def timestamp_now
    Time.now.utc.iso8601
  end

  def stringify_keys(hash)
    hash.each_with_object({}) do |(key, value), memo|
      memo[key.to_s] = value
    end
  end

  def build_progress_message(event)
    case event['type']
    when 'snapshot_list_ready'
      "Found #{event['snapshot_count']} snapshots to consider"
    when 'file_list_ready'
      "Queued #{event['files_total']} files for download"
    when 'file_processed'
      status = event['status'] ? " (#{event['status']})" : ''
      "Processed #{event['processed']}/#{event['files_total']}: #{event['file_url']}#{status}"
    when 'download_finished'
      "Download finished in #{event['duration_seconds']}s"
    when 'download_empty'
      'No downloadable files were found'
    else
      event['message'] || event['type'].to_s.tr('_', ' ').capitalize
    end
  end

  def final_message_for(job)
    case job['status']
    when 'completed'
      if job['artifact_name']
        "Ready: #{job['artifact_name']}"
      else
        'Job completed'
      end
    when 'empty'
      'No files were available for this request'
    else
      job['progress']['last_message']
    end
  end
end
