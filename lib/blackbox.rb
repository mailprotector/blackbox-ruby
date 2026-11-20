require_relative 'blackbox/version'
require_relative 'blackbox/client'
module Blackbox
  class << self
    attr_reader :client
    def configure
      config = Configuration.new
      yield config
      @client&.shutdown(timeout: 1)
      @client = Client.new(config)
    end
    def with_context(values)
      previous = Thread.current[:blackbox_context]
      Thread.current[:blackbox_context] = (previous || {}).merge(values)
      Thread.current[:blackbox_context][:_reported] ||= {}
      yield
    ensure
      Thread.current[:blackbox_context] = previous
    end
    def notify(exception, context: {}, metadata: {}, grouping_key: nil)
      values = (Thread.current[:blackbox_context] || {}).merge(context)
      reported = values[:_reported]
      return false if reported && reported[exception.object_id]
      sent = @client && @client.notify(exception, context: values, metadata: metadata, grouping_key: grouping_key)
      reported[exception.object_id] = true if sent && reported
      !!sent
    rescue StandardError
      false
    end
    def merge_context(values)
      current = Thread.current[:blackbox_context]
      current.merge!(values) if current
    end
    def flush(**options); @client ? @client.flush(**options) : true; end
    def shutdown(**options); @client ? @client.shutdown(**options) : true; end
  end
end
require_relative 'blackbox/integrations'
require_relative 'blackbox/railtie' if defined?(Rails::Railtie)
at_exit { Blackbox.shutdown(timeout: 1) }
