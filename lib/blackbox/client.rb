require 'json'
require 'net/http'
require 'securerandom'
require 'time'
require 'thread'
require_relative 'scrubber'

module Blackbox
  class Configuration
    attr_accessor :endpoint, :token, :project, :environment, :release, :root_directory,
      :capacity, :timeout, :max_attempts, :enabled, :filters, :ignore_environments,
      :transport, :job_adapter, :retriable_wait, :max_retries
    def initialize
      @endpoint = ENV['BLACKBOX_ENDPOINT'].to_s.strip
      @endpoint = 'https://blackbox.mailprotector.dev' if @endpoint.empty?
      @enabled = false
      @capacity = 100
      @timeout = 2.0
      @max_attempts = 3
      @filters = []
      @ignore_environments = %w[test development]
      @job_adapter = :active_job
      @max_retries = 25
    end
    def validate!
      return unless enabled
      uri = URI(endpoint.to_s)
      raise ArgumentError, 'HTTPS origin required' unless uri.scheme == 'https' && uri.host && !uri.userinfo && !uri.query && !uri.fragment && ['', '/'].include?(uri.path)
      raise ArgumentError, 'scoped key required' unless token.to_s.match?(/\A[A-Za-z0-9_-]{32,128}\z/)
      [project, environment].each { |v| raise ArgumentError, 'invalid scope' unless v.to_s.match?(/\A[a-z0-9][a-z0-9_-]{0,62}\z/) }
      raise ArgumentError, 'invalid bounds' unless capacity.is_a?(Integer) && capacity.between?(1, 1000) && timeout.to_f.between?(0.05, 10) && max_attempts.is_a?(Integer) && max_attempts.between?(1, 5)
    end
  end
  class Notice
    attr_reader :exception, :context, :metadata
    def initialize(exception, context, metadata)
      @exception, @context, @metadata, @ignored = exception, context, metadata, false
    end
    def ignore!; @ignored = true; end
    def ignored?; @ignored; end
  end
  class Client
    attr_reader :config
    def initialize(config)
      config.validate!
      @config = config
      reset_process
    end
    def reset_process
      @pid = Process.pid
      @queue = SizedQueue.new(config.capacity)
      @mutex = Mutex.new
      @condition = ConditionVariable.new
      @worker = nil
      @pending = 0
      @closed = false
      @stats = Hash.new(0)
    end
    def process_state
      reset_process if @pid != Process.pid
    end
    def notify(exception, context: {}, metadata: {}, grouping_key: nil)
      return false unless config.enabled && !config.ignore_environments.include?(config.environment.to_s)
      process_state
      return false if @closed
      notice = Notice.new(exception, context, metadata)
      config.filters.each { |filter| filter.call(notice) }
      return false if notice.ignored?
      payload = build_event(notice, grouping_key)
      enqueue('/v1/events', payload)
    rescue StandardError
      increment(:dropped)
      false
    end
    def deploy(revision, deployment_id: SecureRandom.uuid)
      return false unless config.enabled && !config.ignore_environments.include?(config.environment.to_s)
      process_state
      enqueue('/v1/deploys', { schema_version: 1, project: config.project, environment: config.environment,
        deployment_id: deployment_id, revision: Scrubber.text(revision, 200), deployed_at: Time.now.utc.iso8601(3) })
    rescue StandardError
      increment(:dropped)
      false
    end
    def enqueue(path, payload)
      json = JSON.generate(payload)
      return false if json.bytesize > 65_536
      @mutex.synchronize do
        return false if @closed
        @worker ||= Thread.new { delivery_loop }
        @pending += 1
        begin
          @queue.push([path, json], true)
          @stats[:queued] += 1
        rescue ThreadError
          @pending -= 1
          @stats[:dropped] += 1
          return false
        end
      end
      true
    end
    def build_event(notice, grouping_key)
      exception = notice.exception
      root = config.root_directory.to_s.sub(%r{/$}, '')
      frames = Array(exception.backtrace_locations).first(100).map do |frame|
        path = frame.absolute_path || frame.path
        in_app = !root.empty? && path.start_with?(root + '/')
        { file: Scrubber.text(in_app ? path.delete_prefix(root + '/') : frame.path, 500),
          line: [frame.lineno, 1].max, function: Scrubber.text(frame.base_label, 200), in_app: in_app }
      end
      event = { schema_version: 1, occurrence_id: SecureRandom.uuid, project: config.project,
        environment: config.environment, occurred_at: Time.now.utc.iso8601(3),
        error: { type: Scrubber.text(exception.class.name || 'Error', 200), message: Scrubber.text(exception.message.to_s.empty? ? exception.class.name : exception.message), backtrace: frames },
        context: Scrubber.context(notice.context) }
      event[:release] = Scrubber.text(config.release, 200) if config.release && !config.release.empty?
      event[:grouping_key] = Scrubber.text(grouping_key, 200) if grouping_key
      event
    end
    def increment(key)
      @mutex.synchronize { @stats[key] += 1 }
    end
    def delivery_loop
      loop do
        path, json = @queue.pop
        begin
          delivered = false
          config.max_attempts.times do |attempt|
            status = begin
              config.transport ? config.transport.call(path, json) : post(path, json)
            rescue StandardError
              503
            end
            if [201, 202].include?(status)
              delivered = true
              break
            end
            break unless status == 429 || status >= 500
            sleep([0.1 * (2**attempt), 1.0].min) if attempt + 1 < config.max_attempts
          end
          increment(delivered ? :sent : :dropped)
        ensure
          @mutex.synchronize { @pending -= 1; @condition.broadcast }
        end
      end
    end
    def post(path, json)
      uri = URI(config.endpoint.sub(%r{/$}, '') + path)
      http = Net::HTTP.new(uri.host, uri.port, nil)
      http.use_ssl = true
      http.open_timeout = config.timeout
      http.read_timeout = config.timeout
      http.write_timeout = config.timeout
      http.max_retries = 0
      request = Net::HTTP::Post.new(uri.request_uri, 'Content-Type' => 'application/json', 'Authorization' => "Bearer #{config.token}")
      request.body = json
      http.request(request) { |response| return response.code.to_i }
    end
    def flush(timeout: 5)
      process_state
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      @mutex.synchronize do
        while @pending > 0
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          return false unless remaining.positive?
          @condition.wait(@mutex, remaining)
        end
      end
      true
    end
    def shutdown(timeout: 5)
      process_state
      @mutex.synchronize { @closed = true }
      flushed = flush(timeout: timeout)
      @worker&.kill
      @worker&.join(0.05)
      flushed
    end
    def stats
      process_state
      @mutex.synchronize { @stats.merge(pending: @pending) }
    end
  end
end
