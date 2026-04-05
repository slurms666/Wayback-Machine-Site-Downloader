require 'cgi'
require 'erb'
require 'json'
require 'time'
require 'uri'

begin
  require 'webrick'
  require 'webrick/httpservlet/filehandler'
rescue LoadError
  abort 'WEBrick is required to run the web service. Install it with `gem install webrick`.'
end

require_relative 'job_runner'

class WaybackMachineDownloaderWebApp
  DEFAULT_HOST = '127.0.0.1'
  DEFAULT_PORT = 4567
  DEFAULT_WORKER_COUNT = 2

  def initialize(options = {})
    @root_path = options[:root_path] || File.expand_path('../..', File.dirname(__FILE__))
    @views_path = options[:views_path] || File.join(@root_path, 'views')
    @public_path = options[:public_path] || File.join(@root_path, 'public')
    @host = options[:host] || DEFAULT_HOST
    @port = (options[:port] || DEFAULT_PORT).to_i
    storage_path = options[:storage_path] || File.join(@root_path, 'storage')
    worker_count = (options[:worker_count] || DEFAULT_WORKER_COUNT).to_i

    @job_store = options[:job_store] || WaybackMachineDownloaderJobStore.new(storage_path)
    @job_runner = options[:job_runner] || WaybackMachineDownloaderJobRunner.new(@job_store, worker_count)
  end

  def start
    server = WEBrick::HTTPServer.new(
      BindAddress: @host,
      Port: @port,
      AccessLog: [],
      Logger: WEBrick::Log.new($stdout, WEBrick::Log::INFO)
    )

    trap('INT') { server.shutdown }
    trap('TERM') { server.shutdown }

    server.mount('/assets', WEBrick::HTTPServlet::FileHandler, @public_path)
    server.mount_proc('/') do |request, response|
      route request, response
    end

    puts "Wayback Machine web service running at http://#{@host}:#{@port}"
    server.start
  end

  private

  def route(request, response)
    response['Cache-Control'] = 'no-store'

    case [request.request_method, request.path]
    when ['GET', '/']
      render_index response
    when ['POST', '/jobs']
      create_job request, response
    when ['GET', '/health']
      render_json response, { status: 'ok' }
    else
      route_job_request request, response
    end
  rescue ArgumentError => e
    render_index response, e.message, request.query
  rescue StandardError => e
    response.status = 500
    response['Content-Type'] = 'text/html; charset=utf-8'
    response.body = "<h1>Internal Server Error</h1><p>#{CGI.escapeHTML(e.message)}</p>"
  end

  def route_job_request(request, response)
    if request.request_method == 'GET' && request.path =~ %r{\A/jobs/([a-f0-9]+)\.json\z}
      render_job_json response, Regexp.last_match(1)
    elsif request.request_method == 'GET' && request.path =~ %r{\A/jobs/([a-f0-9]+)/download\z}
      download_artifact response, Regexp.last_match(1)
    elsif request.request_method == 'GET' && request.path =~ %r{\A/jobs/([a-f0-9]+)\z}
      render_job response, Regexp.last_match(1)
    else
      response.status = 404
      response['Content-Type'] = 'text/html; charset=utf-8'
      response.body = '<h1>Not Found</h1>'
    end
  end

  def render_index(response, error_message = nil, form_values = {})
    body = render_template('index', {
      recent_jobs: @job_store.list_jobs(12),
      error_message: error_message,
      form_values: default_form_values.merge(form_values || {})
    })
    response.status = 200
    response['Content-Type'] = 'text/html; charset=utf-8'
    response.body = body
  end

  def create_job(request, response)
    options = sanitize_job_options(request.query)
    job = @job_store.create_job(options)
    @job_runner.enqueue(job['id'])

    response.status = 303
    response['Location'] = "/jobs/#{job['id']}"
  end

  def render_job(response, job_id)
    job = @job_store.fetch_job(job_id)
    return render_missing_job(response) unless job

    body = render_template('job', {
      job: public_job_payload(job),
      log_entries: @job_store.tail_log(job_id, 40)
    })
    response.status = 200
    response['Content-Type'] = 'text/html; charset=utf-8'
    response.body = body
  end

  def render_job_json(response, job_id)
    job = @job_store.fetch_job(job_id)
    return render_json(response, { error: 'Job not found' }, 404) unless job

    payload = public_job_payload(job)
    payload[:log_entries] = @job_store.tail_log(job_id, 40)
    render_json response, payload
  end

  def download_artifact(response, job_id)
    job = @job_store.fetch_job(job_id)
    return render_missing_job(response) unless job

    artifact_path = job['artifact_path']
    unless artifact_path && File.exist?(artifact_path)
      return render_json(response, { error: 'Artifact is not ready yet' }, 409)
    end

    response.status = 200
    response['Content-Type'] = job['artifact_content_type'] || 'application/octet-stream'
    response['Content-Disposition'] = "attachment; filename=\"#{job['artifact_name'] || File.basename(artifact_path)}\""
    response['Content-Length'] = File.size(artifact_path).to_s
    response.body = File.open(artifact_path, 'rb')
  end

  def render_missing_job(response)
    render_json response, { error: 'Job not found' }, 404
  end

  def render_json(response, payload, status = 200)
    response.status = status
    response['Content-Type'] = 'application/json; charset=utf-8'
    response.body = JSON.pretty_generate(payload)
  end

  def sanitize_job_options(raw_params)
    exact_url = boolean_param(raw_params['exact_url'])
    from_timestamp = sanitize_timestamp(raw_params['from_timestamp'])
    to_timestamp = sanitize_timestamp(raw_params['to_timestamp'])
    normalized_input = normalize_target_input(raw_params['base_url'], exact_url, from_timestamp, to_timestamp)

    {
      'base_url' => normalized_input[:base_url],
      'exact_url' => exact_url,
      'all_timestamps' => boolean_param(raw_params['all_timestamps']),
      'rewrite_links' => boolean_param(raw_params['rewrite_links']),
      'clean_html' => boolean_param(raw_params['clean_html']),
      'from_timestamp' => normalized_input[:from_timestamp],
      'to_timestamp' => normalized_input[:to_timestamp],
      'only_filter' => sanitize_text(raw_params['only_filter']),
      'exclude_filter' => sanitize_text(raw_params['exclude_filter']),
      'all' => boolean_param(raw_params['all']),
      'threads_count' => clamp_integer(raw_params['threads_count'], 1, 8, 4),
      'maximum_pages' => clamp_integer(raw_params['maximum_pages'], 1, 25, 10),
      'list' => boolean_param(raw_params['list'])
    }.reject { |_, value| value.nil? || value == false || value == '' }
  end

  def normalize_base_url(base_url)
    value = base_url.to_s.strip
    raise ArgumentError, 'Base URL is required' if value.empty?

    value = "http://#{value}" unless value.include?('://')
    uri = URI.parse(value)
    raise ArgumentError, 'Base URL must include a host name' unless uri.host
    raise ArgumentError, 'Only http and https URLs are supported' unless %w(http https).include?(uri.scheme)

    value
  rescue URI::InvalidURIError
    raise ArgumentError, 'Base URL is not a valid URL'
  end

  def normalize_target_input(raw_base_url, exact_url, from_timestamp, to_timestamp)
    normalized_url = normalize_base_url(raw_base_url)
    snapshot_input = parse_wayback_snapshot_url(normalized_url)

    return {
      base_url: normalized_url,
      from_timestamp: from_timestamp,
      to_timestamp: to_timestamp
    } unless snapshot_input

    derived_base_url = exact_url ? snapshot_input[:original_url] : site_root_url(snapshot_input[:original_url])

    {
      base_url: derived_base_url,
      from_timestamp: from_timestamp,
      to_timestamp: to_timestamp || snapshot_input[:timestamp].to_i
    }
  end

  def parse_wayback_snapshot_url(value)
    uri = URI.parse(value)
    host = uri.host.to_s.downcase
    return nil unless host == 'web.archive.org' || host == 'archive.org'

    match = uri.path.match(%r{\A/web/(\d+)(?:[a-z_]+)?/(https?:\/\/.+)\z}i)
    return nil unless match

    original_uri = URI.parse(match[2])
    return nil unless original_uri.host

    {
      timestamp: match[1],
      original_url: original_uri.to_s
    }
  rescue URI::InvalidURIError
    nil
  end

  def site_root_url(value)
    uri = URI.parse(value)
    root = "#{uri.scheme}://#{uri.host}"
    root += ":#{uri.port}" if uri.port && uri.port != uri.default_port
    root
  end

  def sanitize_timestamp(value)
    trimmed = value.to_s.strip
    return nil if trimmed.empty?
    raise ArgumentError, 'Timestamps must be 4 to 14 digits' unless trimmed =~ /\A\d{4,14}\z/

    trimmed.to_i
  end

  def sanitize_text(value, maximum_length = 200)
    trimmed = value.to_s.strip
    return nil if trimmed.empty?
    trimmed[0, maximum_length]
  end

  def clamp_integer(value, minimum, maximum, default)
    parsed = value.to_s.strip
    number = parsed.empty? ? default : parsed.to_i
    [[number, minimum].max, maximum].min
  end

  def boolean_param(value)
    value.to_s == '1' || value.to_s.downcase == 'true' || value.to_s.downcase == 'on'
  end

  def default_form_values
    {
      'rewrite_links' => '1',
      'clean_html' => '1',
      'threads_count' => '4',
      'maximum_pages' => '10'
    }
  end

  def public_job_payload(job)
    {
      id: job['id'],
      status: job['status'],
      created_at: job['created_at'],
      started_at: job['started_at'],
      finished_at: job['finished_at'],
      duration_seconds: job['duration_seconds'],
      error_message: job['error_message'],
      options: job['options'],
      progress: job['progress'],
      artifact_name: job['artifact_name'],
      artifact_size_bytes: job['artifact_size_bytes'],
      can_download: !!(job['artifact_path'] && File.exist?(job['artifact_path'])),
      download_path: job['artifact_path'] && File.exist?(job['artifact_path']) ? "/jobs/#{job['id']}/download" : nil
    }
  end

  def render_template(name, locals)
    context = WaybackMachineDownloaderTemplateContext.new(locals)
    template_path = File.join(@views_path, "#{name}.erb")
    ERB.new(File.read(template_path)).result(context.get_binding)
  end
end

class WaybackMachineDownloaderTemplateContext
  def initialize(locals)
    locals.each do |key, value|
      instance_variable_set("@#{key}", value)
    end
  end

  def get_binding
    binding
  end

  def h(value)
    CGI.escapeHTML(value.to_s)
  end

  def checked?(form_values, key)
    value = form_values[key] || form_values[key.to_sym]
    value.to_s == '1' || value.to_s.downcase == 'true' || value.to_s.downcase == 'on'
  end

  def field_value(form_values, key)
    form_values[key] || form_values[key.to_sym] || ''
  end

  def format_time(value)
    return 'Pending' if value.nil? || value.to_s.empty?
    Time.parse(value.to_s).utc.strftime('%Y-%m-%d %H:%M:%S UTC')
  rescue ArgumentError
    value.to_s
  end

  def format_size(bytes)
    return 'Not generated yet' unless bytes
    units = ['B', 'KB', 'MB', 'GB']
    size = bytes.to_f
    unit = units.shift
    while size >= 1024 && !units.empty?
      size /= 1024.0
      unit = units.shift
    end
    "#{format('%.2f', size)} #{unit}"
  end

  def status_class(status)
    case status.to_s
    when 'completed'
      'status-completed'
    when 'running'
      'status-running'
    when 'failed'
      'status-failed'
    when 'empty'
      'status-empty'
    else
      'status-queued'
    end
  end

  def progress_percent(progress)
    total = progress['files_total'].to_i
    processed = progress['files_processed'].to_i
    return 0 if total <= 0

    [(processed * 100.0 / total).round, 100].min
  end

  def sorted_options(options)
    preferred_order = %w(base_url from_timestamp to_timestamp exact_url all_timestamps rewrite_links clean_html only_filter exclude_filter all threads_count maximum_pages list)
    options.sort_by do |key, _|
      index = preferred_order.index(key.to_s)
      index ? index : preferred_order.length
    end
  end

  def log_message(entry)
    entry['message'] || entry['type'].to_s.tr('_', ' ')
  end
end
