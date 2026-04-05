require 'find'
require 'fileutils'
require 'uri'

require_relative 'path_resolver'

class WaybackMachineDownloaderPostProcessor
  HTML_EXTENSIONS = %w(.html .htm .xhtml .shtml .php .asp .aspx .jsp .cfm .cgi)
  CSS_EXTENSIONS = %w(.css)
  HTML_ATTRIBUTE_NAMES = %w(href src action poster data-src data-href)

  def initialize(root_path, base_url, options = {})
    @root_path = File.expand_path(root_path)
    @base_uri = URI.parse(base_url)
    @rewrite_links = !!options[:rewrite_links]
    @clean_html = !!options[:clean_html]
    @logger = options[:logger]
    @resolver = WaybackMachineDownloaderPathResolver.new
    @internal_hosts = build_internal_hosts(@base_uri.host)
  end

  def run
    return { renamed_paths: 0, rewritten_files: 0, cleaned_files: 0 } unless Dir.exist?(@root_path)

    summary = {
      renamed_paths: normalize_query_paths(@root_path),
      rewritten_files: 0,
      cleaned_files: 0
    }

    Find.find(@root_path) do |path|
      next unless File.file?(path)

      if html_document?(path)
        result = process_html_file(path)
        summary[:rewritten_files] += 1 if result[:rewritten]
        summary[:cleaned_files] += 1 if result[:cleaned]
      elsif css_document?(path)
        summary[:rewritten_files] += 1 if process_css_file(path)
      end
    end

    summary
  end

  private

  def normalize_query_paths(directory)
    renamed = 0
    Dir.entries(directory).each do |entry|
      next if entry == '.' || entry == '..'

      old_path = File.join(directory, entry)
      safe_entry = @resolver.safe_segment(entry)
      if safe_entry != entry
        new_path = File.join(directory, safe_entry)
        FileUtils.mv old_path, new_path
        say "Renamed #{old_path} -> #{new_path}"
        old_path = new_path
        renamed += 1
      end

      renamed += normalize_query_paths(old_path) if File.directory?(old_path)
    end
    renamed
  end

  def process_html_file(path)
    original = read_text_file(path)
    updated = original.dup
    cleaned = false
    rewritten = false
    current_public_path = public_path_for_file(path)

    if @clean_html
      cleaned_html = clean_html_document(updated)
      cleaned = cleaned_html != updated
      updated = cleaned_html
    end

    if @rewrite_links
      rewritten_html = rewrite_html_document(updated, current_public_path)
      rewritten = rewritten_html != updated
      updated = rewritten_html
    end

    if cleaned || rewritten
      File.open(path, 'wb') { |file| file.write(updated) }
      say "Post-processed #{path}"
    end

    { cleaned: cleaned, rewritten: rewritten }
  end

  def process_css_file(path)
    return false unless @rewrite_links

    original = read_text_file(path)
    updated = rewrite_css_content(original, public_path_for_file(path))
    return false if updated == original

    File.open(path, 'wb') { |file| file.write(updated) }
    say "Rewrote CSS URLs in #{path}"
    true
  end

  def clean_html_document(content)
    updated = content.dup
    updated.gsub!(/<!-- BEGIN WAYBACK TOOLBAR INSERT -->.*?<!-- END WAYBACK TOOLBAR INSERT -->/mi, '')
    updated.gsub!(/<base\b[^>]*>\s*/mi, '')
    updated.gsub!(/<link\b(?=[^>]*rel=(['"]).*?\bcanonical\b.*?\1)[^>]*>\s*/mi, '')
    updated.gsub!(/<script\b[^>]+(?:web\.archive\.org|archive\.org)[^>]*>.*?<\/script>\s*/mi, '')
    updated.gsub!(/<link\b[^>]+(?:web\.archive\.org|archive\.org)[^>]*>\s*/mi, '')
    updated
  end

  def rewrite_html_document(content, current_public_path)
    updated = content.dup

    HTML_ATTRIBUTE_NAMES.each do |attribute_name|
      attribute_pattern = /(\b#{Regexp.escape(attribute_name)}\s*=\s*)(["'])(.*?)\2/mi
      updated.gsub!(attribute_pattern) do
        prefix = Regexp.last_match(1)
        quote = Regexp.last_match(2)
        value = Regexp.last_match(3)
        "#{prefix}#{quote}#{rewrite_url_reference(value, current_public_path)}#{quote}"
      end
    end

    updated.gsub!(/(\bsrcset\s*=\s*)(["'])(.*?)\2/mi) do
      prefix = Regexp.last_match(1)
      quote = Regexp.last_match(2)
      value = Regexp.last_match(3)
      "#{prefix}#{quote}#{rewrite_srcset(value, current_public_path)}#{quote}"
    end

    updated.gsub!(/(\bstyle\s*=\s*)(["'])(.*?)\2/mi) do
      prefix = Regexp.last_match(1)
      quote = Regexp.last_match(2)
      value = Regexp.last_match(3)
      "#{prefix}#{quote}#{rewrite_css_content(value, current_public_path)}#{quote}"
    end

    updated.gsub!(/<style\b([^>]*)>(.*?)<\/style>/mi) do
      attributes = Regexp.last_match(1)
      css = Regexp.last_match(2)
      "<style#{attributes}>#{rewrite_css_content(css, current_public_path)}</style>"
    end

    updated.gsub!(/(\bcontent\s*=\s*)(["'])([^"']*?\burl=)([^"']+)\2/mi) do
      prefix = Regexp.last_match(1)
      quote = Regexp.last_match(2)
      leading = Regexp.last_match(3)
      value = Regexp.last_match(4)
      "#{prefix}#{quote}#{leading}#{rewrite_url_reference(value, current_public_path)}#{quote}"
    end

    updated
  end

  def rewrite_srcset(value, current_public_path)
    value.split(',').map do |segment|
      parts = segment.strip.split(/\s+/, 2)
      next segment if parts.empty?

      rewritten_url = rewrite_url_reference(parts[0], current_public_path)
      descriptor = parts[1] ? " #{parts[1]}" : ''
      "#{rewritten_url}#{descriptor}"
    end.join(', ')
  end

  def rewrite_css_content(content, current_public_path)
    updated = content.dup

    updated.gsub!(/url\(\s*(["']?)(.*?)\1\s*\)/mi) do
      quote = Regexp.last_match(1)
      value = Regexp.last_match(2)
      "url(#{quote}#{rewrite_url_reference(value, current_public_path)}#{quote})"
    end

    updated.gsub!(/@import\s+(["'])(.*?)\1/mi) do
      quote = Regexp.last_match(1)
      value = Regexp.last_match(2)
      "@import #{quote}#{rewrite_url_reference(value, current_public_path)}#{quote}"
    end

    updated
  end

  def rewrite_url_reference(value, current_public_path)
    candidate = value.to_s.strip
    return value if candidate.empty?
    return value if candidate.start_with?('#')
    return value if candidate =~ /\A(?:mailto|tel|javascript|data|blob):/i

    unwrapped = unwrap_archive_url(candidate)
    base_uri = URI.parse("#{@base_uri.scheme}://#{@base_uri.host}#{current_public_path}")
    resolved_uri = resolve_uri(unwrapped, base_uri)
    return value unless resolved_uri
    return value unless relative_reference?(unwrapped) || internal_host?(resolved_uri.host)

    resolved_without_fragment = resolved_uri.dup
    resolved_without_fragment.fragment = nil
    rewritten_path = @resolver.public_path_for_url(resolved_without_fragment.to_s)
    return value if rewritten_path.nil? || rewritten_path.empty?

    rewritten_path += "##{resolved_uri.fragment}" if resolved_uri.fragment
    rewritten_path
  rescue URI::InvalidURIError
    value
  end

  def resolve_uri(reference, base_uri)
    if reference.start_with?('//')
      URI.parse("#{@base_uri.scheme}:#{reference}")
    else
      URI.join(base_uri.to_s, reference)
    end
  end

  def unwrap_archive_url(value)
    archive_match = value.match(/\A(?:https?:)?\/\/web\.archive\.org\/web\/\d+(?:[a-z_]+)?\/(https?:\/\/.+)\z/i)
    return archive_match[1] if archive_match

    path_match = value.match(/\A\/web\/\d+(?:[a-z_]+)?\/(https?:\/\/.+)\z/i)
    path_match ? path_match[1] : value
  end

  def relative_reference?(value)
    value !~ /\A(?:[a-z][a-z0-9+\-.]*:)?\/\//i && value !~ /\A[a-z][a-z0-9+\-.]*:/i
  end

  def internal_host?(host)
    return false if host.nil?

    @internal_hosts.include?(normalize_host(host))
  end

  def normalize_host(host)
    host.to_s.downcase.sub(/\Awww\./, '')
  end

  def build_internal_hosts(host)
    normalized = normalize_host(host)
    [normalized, "www.#{normalized}"]
  end

  def public_path_for_file(path)
    relative_path = path.sub(/\A#{Regexp.escape(@root_path)}[\\\/]?/, '')
    @resolver.public_path_for_relative_storage_path(relative_path)
  end

  def html_document?(path)
    HTML_EXTENSIONS.include?(File.extname(path).downcase)
  end

  def css_document?(path)
    CSS_EXTENSIONS.include?(File.extname(path).downcase)
  end

  def read_text_file(path)
    File.binread(path).force_encoding('UTF-8').encode('UTF-8', 'UTF-8', invalid: :replace, undef: :replace, replace: '')
  end

  def say(message)
    return unless @logger
    @logger.call(message)
  end
end
