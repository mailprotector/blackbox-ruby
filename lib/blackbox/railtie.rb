module Blackbox
  class Railtie < Rails::Railtie
    initializer 'blackbox.rack' do |app|
      app.middleware.insert_before ActionDispatch::ShowExceptions, Blackbox::RackMiddleware
    end
    initializer 'blackbox.active_job' do
      ActiveSupport.on_load(:active_job) do
        around_perform do |job, block|
          if Blackbox.client&.config&.job_adapter == :active_job
            Blackbox.with_context(component: 'active_job', job: { class: job.class.name, queue: job.queue_name }) do
              begin
                block.call
              rescue Exception => error
                Blackbox.notify(error)
                raise
              end
            end
          else
            block.call
          end
        end
      end
    end
    config.after_initialize do
      if defined?(Sidekiq) && Blackbox.client&.config&.job_adapter == :sidekiq
        Sidekiq.configure_server { |c| c.server_middleware { |chain| chain.add Blackbox::SidekiqMiddleware } }
      end
      if defined?(Shoryuken) && Blackbox.client&.config&.job_adapter == :shoryuken
        Shoryuken.configure_server { |c| c.server_middleware { |chain| chain.add Blackbox::ShoryukenMiddleware } }
      end
    end
  end
end
