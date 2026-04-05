require 'minitest/autorun'

require_relative '../lib/wayback_machine_downloader'

class WaybackMachineDownloaderNetworkRetryTest < Minitest::Test
  FakeResponse = Struct.new(:body) do
    def read
      body
    end
  end

  class RetryTestDownloader < WaybackMachineDownloader
    attr_reader :open_attempts

    def initialize(sequence)
      super(base_url: 'http://example.com', request_retries: 3, open_timeout: 1, read_timeout: 1, logger: proc { |_msg| })
      @sequence = sequence
      @open_attempts = 0
    end

    def try_fetch(uri_string)
      send(:fetch_uri_with_retries, URI(uri_string)) do |response|
        response.read
      end
    end

    def uri_open(_uri, _options = {})
      @open_attempts += 1
      current = @sequence.shift
      raise current if current.is_a?(Exception)
      yield FakeResponse.new(current)
    end

    def sleep(_seconds)
    end
  end

  def test_fetch_uri_with_retries_retries_then_succeeds
    downloader = RetryTestDownloader.new([
      Net::OpenTimeout.new('execution expired'),
      Net::ReadTimeout.new('timed out'),
      'ok'
    ])

    assert_equal 'ok', downloader.try_fetch('https://example.com')
    assert_equal 3, downloader.open_attempts
  end

  def test_fetch_uri_with_retries_raises_after_final_attempt
    downloader = RetryTestDownloader.new([
      Net::OpenTimeout.new('execution expired'),
      Net::OpenTimeout.new('execution expired'),
      Net::OpenTimeout.new('execution expired')
    ])

    assert_raises(Net::OpenTimeout) do
      downloader.try_fetch('https://example.com')
    end
    assert_equal 3, downloader.open_attempts
  end
end
