require 'find'
require 'fileutils'
require 'rubygems/package'
require 'zlib'

class WaybackMachineDownloaderArchiveBuilder
  def initialize(source_path, archive_path, options = {})
    @source_path = File.expand_path(source_path)
    @archive_path = File.expand_path(archive_path)
    @root_directory_name = options[:root_directory_name]
  end

  def build
    raise ArgumentError, "Source path does not exist: #{@source_path}" unless Dir.exist?(@source_path)

    tar_path = temporary_tar_path
    FileUtils.mkdir_p File.dirname(@archive_path)
    FileUtils.rm_f tar_path
    FileUtils.rm_f @archive_path

    File.open(tar_path, 'wb') do |tar_file|
      Gem::Package::TarWriter.new(tar_file) do |tar|
        write_entries tar
      end
    end

    Zlib::GzipWriter.open(@archive_path) do |gzip_file|
      File.open(tar_path, 'rb') do |tar_file|
        IO.copy_stream tar_file, gzip_file
      end
    end

    @archive_path
  ensure
    FileUtils.rm_f(tar_path) if tar_path && File.exist?(tar_path)
  end

  private

  def write_entries(tar)
    Find.find(@source_path) do |path|
      relative_path = path.sub(/\A#{Regexp.escape(@source_path)}[\\\/]?/, '')
      next if relative_path.empty?

      entry_path = if @root_directory_name
        File.join(@root_directory_name, relative_path)
      else
        relative_path
      end.tr('\\', '/')

      stat = File.stat(path)
      if File.directory?(path)
        tar.mkdir entry_path, stat.mode
      elsif File.file?(path)
        tar.add_file entry_path, stat.mode do |archive_file|
          File.open(path, 'rb') do |source_file|
            IO.copy_stream source_file, archive_file
          end
        end
      end
    end
  end

  def temporary_tar_path
    if @archive_path.end_with?('.tar.gz')
      @archive_path.sub(/\.gz\z/, '')
    else
      @archive_path + '.tar'
    end
  end
end
