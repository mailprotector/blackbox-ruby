require 'minitest/autorun'
require 'tmpdir'
require 'logger'
require 'rails'
require 'action_controller/railtie'
require 'active_job/railtie'
require 'sidekiq'
require 'sidekiq/middleware/chain'
require 'blackbox'

class ProbeApplication < Rails::Application
  config.root = Dir.mktmpdir('blackbox-rails-')
  config.eager_load = false
  config.active_support.to_time_preserves_timezone = :zone
  config.secret_key_base = 'synthetic-test-only-' * 8
  config.hosts.clear
  config.logger = Logger.new(File::NULL)
  config.consider_all_requests_local = false
  config.action_dispatch.show_exceptions = :all
  routes.append { get '/boom', to: ->(_env) { raise 'synthetic Rails failure' } }
end
ProbeApplication.initialize!
ActiveJob::Base.logger = Logger.new(File::NULL)
class ProbeJob < ActiveJob::Base
  def perform; raise 'synthetic job failure'; end
end

class BlackboxFrameworkTest < Minitest::Test
  def setup
    @sent = Queue.new
    Blackbox.configure do |c|
      c.enabled = true; c.endpoint = 'https://blackbox.example.test'; c.token = 'synthetic-key-not-a-real-credential-12345'
      c.project = 'shield'; c.environment = 'staging'; c.transport = ->(_path, json) { @sent << JSON.parse(json); 202 }
      c.filters << Blackbox::ShieldFilter
    end
  end
  def teardown; Blackbox.shutdown(timeout: 0.1); end
  def test_rails_reports_a_rendered_exception_once
    response = Rack::MockRequest.new(ProbeApplication).get('/boom')
    assert_equal 500, response.status
    assert Blackbox.flush
    assert_equal 1, @sent.size
    assert_equal 'rack', @sent.pop['context']['component']
  end
  def test_active_job_reports_and_preserves_failure
    assert_raises(RuntimeError) { ProbeJob.perform_now }
    assert Blackbox.flush
    assert_equal 1, @sent.size
    assert_equal 'ProbeJob', @sent.pop['context']['job']['class']
  end
  def test_sidekiq_adapter_avoids_nested_active_job_duplicates
    Blackbox.client.config.job_adapter = :sidekiq
    chain = Sidekiq::Middleware::Chain.new
    chain.add Blackbox::SidekiqMiddleware
    assert_raises(RuntimeError) { chain.invoke(nil, { 'class' => 'ProbeJob', 'retry' => true }, 'default') { ProbeJob.perform_now } }
    assert Blackbox.flush
    assert_equal 1, @sent.size
    assert_equal 'sidekiq', @sent.pop['context']['component']
  end
end
