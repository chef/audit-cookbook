# encoding: utf-8

module ReportHelpers
  # Returns the uuid for the current converge
  def run_id
    return unless run_context &&
                  run_context.events &&
                  run_context.events.subscribers.is_a?(Array)
    run_context.events.subscribers.each do |sub|
      if sub.class == Chef::ResourceReporter && defined?(sub.run_id)
        return sub.run_id
      end
    end
    nil
  end

  # Returns the node's uuid
  def entity_uuid
    if defined?(Chef) &&
       defined?(Chef::DataCollector) &&
       defined?(Chef::DataCollector::Messages) &&
       defined?(Chef::DataCollector::Messages.node_uuid)
      return Chef::DataCollector::Messages.node_uuid
    end
  end

  # Convert the strings in the profile definitions into symbols for handling
  def tests_for_runner(profiles)
    tests_for_runner = profiles.map { |profile| Hash[profile.map { |k, v| [k.to_sym, v] }] }
    tests_for_runner
  end

  def construct_url(server, path)
    # sanitize inputs
    server << '/' unless server =~ %r{/\z}
    path.sub!(%r{^/}, '')
    server = URI(server)
    server.path = server.path + path if path
    server
  end

  def with_http_rescue(*)
    response = yield
    if response.respond_to?(:code)
      # handle non 200 error codes, they are not raised as Net::HTTPServerException
      handle_http_error_code(response.code) if response.code.to_i >= 300
    end
    return response
  rescue Net::HTTPServerException => e
    Chef::Log.error e
    handle_http_error_code(e.response.code)
  end

  def handle_http_error_code(code)
    case code
    when /401|403/
      Chef::Log.error 'Auth issue: see audit cookbook TROUBLESHOOTING.md'
    when /404/
      Chef::Log.error 'Object does not exist on remote server.'
    end
    msg = "Received HTTP error #{code}"
    Chef::Log.error msg
    raise msg if @raise_if_unreachable
  end

  def base_chef_server_url
    cs = URI(Chef::Config[:chef_server_url])
    cs.path = ''
    cs.to_s
  end

  def profile_overdue_to_run?(interval)
    # Calculate when a report was last created so we delay the next report if necessary
    file = File.expand_path('../../report_timing.json', __FILE__)
    return true unless ::File.exist?(file)
    seconds_since_last_run = Time.now - ::File.mtime(file)
    seconds_since_last_run > interval
  end

  def check_interval_settings(interval, interval_enabled, interval_time)
    # handle intervals
    interval_seconds = 0 # always run this by default, unless interval is defined
    if !interval.nil? && interval_enabled
      interval_seconds = interval_time * 60 # seconds in interval
      Chef::Log.debug "Auditing this machine every #{interval_seconds} seconds "
    end
    # returns true if profile is overdue to run
    profile_overdue_to_run?(interval_seconds)
  end

  # used for interval timing
  def create_timestamp_file
    path = File.expand_path('../../report_timing.json', __FILE__)
    timestamp = Time.now.utc
    timestamp_file = File.new(path, 'w')
    timestamp_file.puts(timestamp)
    timestamp_file.close
  end

  # takes value of reporters and returns array to ensure backwards-compatibility
  def handle_reporters(reporters)
    return reporters if reporters.is_a? Array
    [reporters]
  end

  def cookbook_vendor_path
    File.expand_path('../../files/default/vendor', __FILE__)
  end

  def cookbook_handler_path
    File.expand_path('../../files/default/handler', __FILE__)
  end

  def load_audit_handler
    libpath = ::File.join(cookbook_handler_path, 'audit_report')
    Chef::Log.info("loading handler from #{libpath}")
    $LOAD_PATH.unshift(libpath) unless $LOAD_PATH.include?(libpath)
    require libpath
    Chef::Config.send('report_handlers') << Chef::Handler::AuditReport.new
  end
end

::Chef::Recipe.send(:include, ReportHelpers)
