require 'fileutils'
require 'tmpdir'
require 'minitest/autorun'

require_relative '../lib/wayback_machine_downloader/post_processor'

class WaybackMachineDownloaderPostProcessorTest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @site_root = File.join(@tmpdir, 'site')
    FileUtils.mkdir_p File.join(@site_root, 'img')
    FileUtils.mkdir_p File.join(@site_root, 'styles')
    FileUtils.mkdir_p File.join(@site_root, 'about')

    File.open(File.join(@site_root, 'index.html'), 'wb') do |file|
      file.write <<-HTML
        <html>
          <head>
            <base href="https://example.com/">
            <link rel="canonical" href="https://example.com/">
            <style>.hero { background-image: url("https://example.com/img/logo.png?ver=2"); }</style>
          </head>
          <body>
            <a href="https://example.com/about">About</a>
            <img src="https://example.com/img/logo.png?ver=2">
          </body>
        </html>
      HTML
    end

    File.open(File.join(@site_root, 'styles', 'site.css'), 'wb') do |file|
      file.write '.logo { background: url("https://example.com/img/logo.png?ver=2"); }'
    end

    File.open(File.join(@site_root, 'img', 'logo.png?ver=2'), 'wb') do |file|
      file.write 'PNG'
    end

    File.open(File.join(@site_root, 'about', 'index.html'), 'wb') do |file|
      file.write '<h1>About</h1>'
    end
  end

  def teardown
    FileUtils.rm_rf @tmpdir
  end

  def test_post_processor_rewrites_internal_links_and_cleans_html
    summary = WaybackMachineDownloaderPostProcessor.new(
      @site_root,
      'https://example.com',
      rewrite_links: true,
      clean_html: true
    ).run

    assert summary[:renamed_paths] > 0
    assert summary[:rewritten_files] > 0
    assert summary[:cleaned_files] > 0

    processed_index = File.read(File.join(@site_root, 'index.html'))
    refute_match(/<base\b/i, processed_index)
    refute_match(/canonical/i, processed_index)
    assert_includes processed_index, 'href="/about/"'
    assert_match(%r{src="/img/logo__wbm_q_ver-2-}, processed_index)
    assert_match(%r{url\("/img/logo__wbm_q_ver-2-}, processed_index)

    processed_css = File.read(File.join(@site_root, 'styles', 'site.css'))
    assert_match(%r{/img/logo__wbm_q_ver-2-}, processed_css)

    renamed_asset = Dir.glob(File.join(@site_root, 'img', 'logo__wbm_q_ver-2-*')).first
    refute_nil renamed_asset
    assert File.exist?(renamed_asset)
  end
end
