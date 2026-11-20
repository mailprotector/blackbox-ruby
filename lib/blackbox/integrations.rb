module Blackbox
  class RackMiddleware
    def initialize(app); @app = app; end
    def call(env)
      Blackbox.with_context(component: 'rack', request: { method: env['REQUEST_METHOD'], path: env['PATH_INFO'] }) do
        begin
          result = @app.call(env)
          error = env['action_dispatch.exception']
          Blackbox.notify(error) if error
          result
        rescue Exception => error # Report, then re-raise the original application exception.
          Blackbox.notify(error)
          raise
        end
      end
    end
  end
  class SidekiqMiddleware
    def call(_worker, job, queue)
      Blackbox.with_context(component: 'sidekiq', job: { class: job['wrapped'] || job['class'], queue: queue }) do
        begin
          yield
        rescue Exception => error
          Blackbox.notify(error, metadata: { job: job })
          raise
        end
      end
    end
  end
  class ShoryukenMiddleware
    def call(worker, queue, _message, _body)
      Blackbox.with_context(component: 'shoryuken', job: { class: worker.class.name, queue: queue }) do
        begin
          yield
        rescue Exception => error
          Blackbox.notify(error)
          raise
        end
      end
    end
  end
  module ShieldFilter
    module_function
    def call(notice)
      error, context = notice.exception, notice.context
      if (error.is_a?(SignalException) && %w[SIGHUP SIGTERM].include?(error.message)) || error.class.name == 'Searchkick::ImportError' ||
        (error.class.name == 'ActiveJob::DeserializationError' && error.message.include?("Couldn't find ActiveStorage::Blob with 'id'=")) || context[:ignore_error]
        notice.ignore!
      end
      config = Blackbox.client&.config
      return unless config
      notice.ignore! if context[:component] == 'active_job' && config.job_adapter != :active_job
      if config.retriable_wait && config.retriable_wait.call(error)
        job = notice.metadata[:job]
        if job && job['retry']
          max = job['retry'].is_a?(Integer) ? job['retry'] : config.max_retries
          notice.ignore! if (job['retry_count'] || -1) + 1 < max
        end
      end
    end
  end
end
