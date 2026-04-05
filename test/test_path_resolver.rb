require 'minitest/autorun'

require_relative '../lib/wayback_machine_downloader/path_resolver'

class WaybackMachineDownloaderPathResolverTest < Minitest::Test
  def setup
    @resolver = WaybackMachineDownloaderPathResolver.new
  end

  def test_safe_segment_normalizes_windows_escaped_query_chars
    safe_segment = @resolver.safe_segment('logo.png%3fver%3d2')
    assert_match(/\Alogo__wbm_q_ver-2-/, safe_segment)
    assert_match(/\.png\z/, safe_segment)
  end

  def test_public_path_for_url_uses_directory_indexes_for_extensionless_paths
    assert_equal '/about/', @resolver.public_path_for_url('https://example.com/about')
    assert_equal '/assets/app.css', @resolver.public_path_for_url('https://example.com/assets/app.css')
  end
end
