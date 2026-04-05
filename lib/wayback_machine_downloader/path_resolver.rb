require 'cgi'
require 'digest/sha1'
require_relative 'tidy_bytes'

class WaybackMachineDownloaderPathResolver
  INDEX_FILE = 'index.html'

  def relative_storage_path_for_url(file_url)
    file_id = file_id_for_url(file_url)
    path_elements = file_id.split('/')

    if file_id == ""
      INDEX_FILE
    elsif file_url[-1] == '/' || !path_elements[-1].include?('.')
      File.join(*(path_elements + [INDEX_FILE]))
    else
      File.join(*path_elements)
    end
  end

  def safe_relative_storage_path(relative_path)
    relative_path.split(/[\\\/]/).map { |segment| safe_segment(segment) }.join('/')
  end

  def public_path_for_relative_storage_path(relative_path)
    normalized = relative_path.tr('\\', '/')
    if normalized == INDEX_FILE
      '/'
    elsif normalized.end_with?("/#{INDEX_FILE}")
      '/' + normalized.sub(/\/index\.html\z/, '/') 
    else
      '/' + normalized
    end
  end

  def public_path_for_url(file_url)
    public_path_for_relative_storage_path(
      safe_relative_storage_path(relative_storage_path_for_url(file_url))
    )
  end

  def safe_segment(segment)
    decoded_segment = decode_windows_escaped_query_chars(segment)
    return segment unless decoded_segment.include?('?')

    base, query = decoded_segment.split('?', 2)
    token = safe_query_token(query)

    if base.nil? || base.empty?
      "__wbm_q_#{token}"
    elsif base.include?('.')
      extension = File.extname(base)
      if extension.nil? || extension.empty?
        "#{base}__wbm_q_#{token}"
      else
        stem = base[0...-extension.length]
        "#{stem}__wbm_q_#{token}#{extension}"
      end
    else
      "#{base}__wbm_q_#{token}"
    end
  end

  private

  def file_id_for_url(file_url)
    url_parts = file_url.split('/')[3..-1] || []
    file_id = CGI.unescape(url_parts.join('/'))
    cleaned_file_id = file_id == "" ? "" : file_id.tidy_bytes
    cleaned_file_id || ""
  end

  def safe_query_token(query)
    base = query.to_s.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/\A-+|-+\z/, '')
    digest = Digest::SHA1.hexdigest(query.to_s)[0, 8]
    base = base[0, 40]
    base.empty? ? digest : "#{base}-#{digest}"
  end

  def decode_windows_escaped_query_chars(segment)
    segment.to_s.
      gsub(/%3f/i, '?').
      gsub(/%3d/i, '=').
      gsub(/%26/i, '&')
  end
end
