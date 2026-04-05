require 'fileutils'
require 'tmpdir'
require 'zlib'
require 'rubygems/package'
require 'minitest/autorun'

require_relative '../lib/wayback_machine_downloader/archive_builder'

class WaybackMachineDownloaderArchiveBuilderTest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @source_path = File.join(@tmpdir, 'site')
    FileUtils.mkdir_p File.join(@source_path, 'nested')
    File.open(File.join(@source_path, 'index.html'), 'wb') { |file| file.write('<h1>Hello</h1>') }
    File.open(File.join(@source_path, 'nested', 'about.txt'), 'wb') { |file| file.write('about page') }
  end

  def teardown
    FileUtils.rm_rf @tmpdir
  end

  def test_build_creates_a_tar_gz_archive
    archive_path = File.join(@tmpdir, 'download.tar.gz')

    result = WaybackMachineDownloaderArchiveBuilder.new(
      @source_path,
      archive_path,
      root_directory_name: 'example-site'
    ).build

    assert_equal archive_path, result
    assert File.exist?(archive_path)
    assert File.size(archive_path) > 0

    entries = []
    File.open(archive_path, 'rb') do |archive_file|
      Zlib::GzipReader.wrap(archive_file) do |gzip_reader|
        Gem::Package::TarReader.new(gzip_reader) do |tar_reader|
          tar_reader.each do |entry|
            entries << entry.full_name
          end
        end
      end
    end

    assert_includes entries, 'example-site/index.html'
    assert_includes entries, 'example-site/nested/about.txt'
  end
end
