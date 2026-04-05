# encoding: UTF-8

require 'thread'
require 'net/http'
require 'open-uri'
require 'fileutils'
require 'cgi'
require 'json'
require 'time'
require_relative 'wayback_machine_downloader/tidy_bytes'
require_relative 'wayback_machine_downloader/to_regex'
require_relative 'wayback_machine_downloader/archive_api'

class WaybackMachineDownloader

  include ArchiveAPI

  VERSION = "2.3.1"

  attr_accessor :base_url, :exact_url, :directory, :all_timestamps,
    :from_timestamp, :to_timestamp, :only_filter, :exclude_filter, 
    :all, :maximum_pages, :threads_count

  def initialize params
    @base_url = params[:base_url]
    @exact_url = params[:exact_url]
    @directory = params[:directory]
    @all_timestamps = params[:all_timestamps]
    @from_timestamp = params[:from_timestamp].to_i
    @to_timestamp = params[:to_timestamp].to_i
    @only_filter = params[:only_filter]
    @exclude_filter = params[:exclude_filter]
    @all = params[:all]
    @maximum_pages = params[:maximum_pages] ? params[:maximum_pages].to_i : 100
    @threads_count = params[:threads_count].to_i
    @logger = params[:logger]
    @event_callback = params[:event_callback]
    @log_io = params[:log_io] || $stdout
  end

  def backup_name
    if @base_url.include? '//'
      @base_url.split('/')[2]
    else
      @base_url
    end
  end

  def backup_path
    if @directory
      if @directory[-1] == '/'
        @directory
      else
        @directory + '/'
      end
    else
      'websites/' + backup_name + '/'
    end
  end

  def match_only_filter file_url
    if @only_filter
      only_filter_regex = @only_filter.to_regex
      if only_filter_regex
        only_filter_regex =~ file_url
      else
        file_url.downcase.include? @only_filter.downcase
      end
    else
      true
    end
  end

  def match_exclude_filter file_url
    if @exclude_filter
      exclude_filter_regex = @exclude_filter.to_regex
      if exclude_filter_regex
        exclude_filter_regex =~ file_url
      else
        file_url.downcase.include? @exclude_filter.downcase
      end
    else
      false
    end
  end

  def get_all_snapshots_to_consider
    # Note: Passing a page index parameter allow us to get more snapshots,
    # but from a less fresh index
    say "Getting snapshot pages"
    snapshot_list_to_consider = []
    snapshot_list_to_consider += get_raw_list_from_api(@base_url, nil)
    notify :snapshot_page_loaded, page_index: nil, snapshot_count: snapshot_list_to_consider.length
    unless @exact_url
      @maximum_pages.times do |page_index|
        snapshot_list = get_raw_list_from_api(@base_url + '/*', page_index)
        break if snapshot_list.empty?
        snapshot_list_to_consider += snapshot_list
        notify :snapshot_page_loaded, page_index: page_index, snapshot_count: snapshot_list.length
      end
    end
    say "Found #{snapshot_list_to_consider.length} snapshots to consider."
    say
    notify :snapshot_list_ready, snapshot_count: snapshot_list_to_consider.length
    snapshot_list_to_consider
  end

  def get_file_list_curated
    file_list_curated = Hash.new
    get_all_snapshots_to_consider.each do |file_timestamp, file_url|
      next unless file_url.include?('/')
      file_id = file_url.split('/')[3..-1].join('/')
      file_id = CGI::unescape file_id 
      file_id = file_id.tidy_bytes unless file_id == ""
      if file_id.nil?
        say "Malformed file url, ignoring: #{file_url}"
      else
        if match_exclude_filter(file_url)
          say "File url matches exclude filter, ignoring: #{file_url}"
        elsif not match_only_filter(file_url)
          say "File url doesn't match only filter, ignoring: #{file_url}"
        elsif file_list_curated[file_id]
          unless file_list_curated[file_id][:timestamp] > file_timestamp
            file_list_curated[file_id] = {file_url: file_url, timestamp: file_timestamp}
          end
        else
          file_list_curated[file_id] = {file_url: file_url, timestamp: file_timestamp}
        end
      end
    end
    file_list_curated
  end

  def get_file_list_all_timestamps
    file_list_curated = Hash.new
    get_all_snapshots_to_consider.each do |file_timestamp, file_url|
      next unless file_url.include?('/')
      file_id = file_url.split('/')[3..-1].join('/')
      file_id_and_timestamp = [file_timestamp, file_id].join('/')
      file_id_and_timestamp = CGI::unescape file_id_and_timestamp 
      file_id_and_timestamp = file_id_and_timestamp.tidy_bytes unless file_id_and_timestamp == ""
      if file_id.nil?
        say "Malformed file url, ignoring: #{file_url}"
      else
        if match_exclude_filter(file_url)
          say "File url matches exclude filter, ignoring: #{file_url}"
        elsif not match_only_filter(file_url)
          say "File url doesn't match only filter, ignoring: #{file_url}"
        elsif file_list_curated[file_id_and_timestamp]
          say "Duplicate file and timestamp combo, ignoring: #{file_id}" if @verbose
        else
          file_list_curated[file_id_and_timestamp] = {file_url: file_url, timestamp: file_timestamp}
        end
      end
    end
    say "file_list_curated: " + file_list_curated.count.to_s
    file_list_curated
  end


  def get_file_list_by_timestamp
    if @all_timestamps
      file_list_curated = get_file_list_all_timestamps
      file_list_curated.map do |file_remote_info|
        file_remote_info[1][:file_id] = file_remote_info[0]
        file_remote_info[1]
      end
    else
      file_list_curated = get_file_list_curated
      file_list_curated = file_list_curated.sort_by { |k,v| v[:timestamp] }.reverse
      file_list_curated.map do |file_remote_info|
        file_remote_info[1][:file_id] = file_remote_info[0]
        file_remote_info[1]
      end
    end
  end

  def list_files_data
    get_file_list_by_timestamp
  end

  def list_files
    files = if @logger
      list_files_data
    else
      with_log_io($stderr) { list_files_data }
    end
    puts JSON.pretty_generate(files)
    files
  end

  def download_files
    start_time = Time.now
    say "Downloading #{@base_url} to #{backup_path} from Wayback Machine archives."
    say
    notify :download_started, base_url: @base_url, backup_path: backup_path

    files = file_list_by_timestamp
    if files.count == 0
      reasons = ["Site is not in Wayback Machine Archive."]
      reasons << "From timestamp too much in the future." if @from_timestamp and @from_timestamp != 0
      reasons << "To timestamp too much in the past." if @to_timestamp and @to_timestamp != 0
      reasons << "Only filter too restrictive (#{only_filter.to_s})" if @only_filter
      reasons << "Exclude filter too wide (#{exclude_filter.to_s})" if @exclude_filter
      say "No files to download."
      say "Possible reasons:"
      reasons.each do |reason|
        say "\t* #{reason}"
      end
      notify :download_empty, files_total: 0, reasons: reasons
      return {
        status: :empty,
        files_total: 0,
        backup_path: backup_path,
        reasons: reasons
      }
    end
 
    total_files = files.count
    say "#{total_files} files to download:"
    notify :file_list_ready, files_total: total_files

    threads = []
    @processed_file_count = 0
    @threads_count = 1 unless @threads_count != 0
    @threads_count.times do
      threads << Thread.new do
        until file_queue.empty?
          file_remote_info = file_queue.pop(true) rescue nil
          download_file(file_remote_info) if file_remote_info
        end
      end
    end

    threads.each(&:join)
    end_time = Time.now
    duration_seconds = (end_time - start_time).round(2)
    say
    say "Download completed in #{duration_seconds}s, saved in #{backup_path} (#{total_files} files)"
    notify :download_finished, duration_seconds: duration_seconds, backup_path: backup_path, files_total: total_files
    {
      status: :completed,
      files_total: total_files,
      backup_path: backup_path,
      duration_seconds: duration_seconds
    }
  end

  def structure_dir_path dir_path
    begin
      FileUtils::mkdir_p dir_path unless File.exist? dir_path
    rescue Errno::EEXIST => e
      error_to_string = e.to_s
      say "# #{error_to_string}"
      if error_to_string.include? "File exists @ dir_s_mkdir - "
        file_already_existing = error_to_string.split("File exists @ dir_s_mkdir - ")[-1]
      elsif error_to_string.include? "File exists - "
        file_already_existing = error_to_string.split("File exists - ")[-1]
      else
        raise "Unhandled directory restructure error # #{error_to_string}"
      end
      file_already_existing_temporary = file_already_existing + '.temp'
      file_already_existing_permanent = file_already_existing + '/index.html'
      FileUtils::mv file_already_existing, file_already_existing_temporary
      FileUtils::mkdir_p file_already_existing
      FileUtils::mv file_already_existing_temporary, file_already_existing_permanent
      say "#{file_already_existing} -> #{file_already_existing_permanent}"
      structure_dir_path dir_path
    end
  end

  def download_file file_remote_info
    current_encoding = "".encoding
    file_url = file_remote_info[:file_url].encode(current_encoding)
    file_id = file_remote_info[:file_id]
    file_timestamp = file_remote_info[:timestamp]
    file_path_elements = file_id.split('/')
    if file_id == ""
      dir_path = backup_path
      file_path = backup_path + 'index.html'
    elsif file_url[-1] == '/' or not file_path_elements[-1].include? '.'
      dir_path = backup_path + file_path_elements[0..-1].join('/')
      file_path = backup_path + file_path_elements[0..-1].join('/') + '/index.html'
    else
      dir_path = backup_path + file_path_elements[0..-2].join('/')
      file_path = backup_path + file_path_elements[0..-1].join('/')
    end
    if Gem.win_platform?
      dir_path = dir_path.gsub(/[:*?&=<>\\|]/) {|s| '%' + s.ord.to_s(16) }
      file_path = file_path.gsub(/[:*?&=<>\\|]/) {|s| '%' + s.ord.to_s(16) }
    end
    unless File.exist? file_path
      result_status = 'downloaded'
      error_message = nil
      begin
        structure_dir_path dir_path
        open(file_path, "wb") do |file|
          begin
            URI("https://web.archive.org/web/#{file_timestamp}id_/#{file_url}").open("Accept-Encoding" => "plain") do |uri|
              file.write(uri.read)
            end
          rescue OpenURI::HTTPError => e
            error_message = e.to_s
            say "#{file_url} # #{e}"
            if @all
              file.write(e.io.read)
              result_status = 'saved_error_response'
              say "#{file_path} saved anyway."
            else
              result_status = 'http_error'
            end
          rescue StandardError => e
            result_status = 'error'
            error_message = e.to_s
            say "#{file_url} # #{e}"
          end
        end
      rescue StandardError => e
        result_status = 'error'
        error_message = e.to_s
        say "#{file_url} # #{e}"
      ensure
        if not @all and File.exist?(file_path) and File.size(file_path) == 0
          File.delete(file_path)
          result_status = 'empty_removed'
          say "#{file_path} was empty and was removed."
        end
      end
      semaphore.synchronize do
        @processed_file_count += 1
        processed = @processed_file_count
        say "#{file_url} -> #{file_path} (#{processed}/#{file_list_by_timestamp.size})"
        notify :file_processed,
          file_url: file_url,
          file_path: file_path,
          processed: processed,
          files_total: file_list_by_timestamp.size,
          status: result_status,
          error: error_message
      end
    else
      semaphore.synchronize do
        @processed_file_count += 1
        processed = @processed_file_count
        say "#{file_url} # #{file_path} already exists. (#{processed}/#{file_list_by_timestamp.size})"
        notify :file_processed,
          file_url: file_url,
          file_path: file_path,
          processed: processed,
          files_total: file_list_by_timestamp.size,
          status: 'already_exists'
      end
    end
  end

  def file_queue
    @file_queue ||= file_list_by_timestamp.each_with_object(Queue.new) { |file_info, q| q << file_info }
  end

  def file_list_by_timestamp
    @file_list_by_timestamp ||= get_file_list_by_timestamp
  end

  def semaphore
    @semaphore ||= Mutex.new
  end

  private

  def say(message = "")
    if @logger
      @logger.call(message.to_s)
    else
      @log_io.puts(message.to_s)
    end
  end

  def notify(type, data = {})
    return unless @event_callback
    payload = { type: type.to_s, timestamp: Time.now.utc.iso8601 }
    data.each do |key, value|
      payload[key] = value
    end
    @event_callback.call(payload)
  end

  def with_log_io(io)
    previous_log_io = @log_io
    @log_io = io
    yield
  ensure
    @log_io = previous_log_io
  end
end
