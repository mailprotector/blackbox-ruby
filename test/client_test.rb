require 'minitest/autorun'
require 'blackbox'
class BlackboxClientTest < Minitest::Test
  def setup
    @sent = Queue.new
    Blackbox.configure do |c|
      c.enabled = true; c.endpoint = 'https://blackbox.example.test'; c.token = 'synthetic-key-not-a-real-credential-12345'
      c.project = 'shield'; c.environment = 'staging'; c.transport = ->(path, json) { @sent << [path, JSON.parse(json)]; 202 }
    end
  end
  def teardown; Blackbox.shutdown(timeout: 0.1); end
  def test_redaction_and_context_allowlist
    Blackbox.notify(RuntimeError.new('failed /xray/shares/Secret123?token=secret'), context: { request: { method: 'GET', path: '/xray/shares/Secret123', body: 'email-body', headers: { cookie: 'secret' } }, arguments: ['secret'] })
    assert Blackbox.flush
    json = JSON.generate(@sent.pop[1])
    refute_includes json, 'Secret123'; refute_includes json, 'email-body'; refute_includes json, 'arguments'
  end
  def test_scoped_context_and_duplicate_suppression
    error = RuntimeError.new('synthetic')
    Blackbox.with_context(component: 'rack') do
      assert Blackbox.notify(error)
      refute Blackbox.notify(error)
    end
    assert Blackbox.notify(error)
    assert Blackbox.flush
    assert_equal 2, @sent.size
    assert_equal 'rack', @sent.pop[1]['context']['component']
    refute @sent.pop[1]['context'].key?('component')
  end
  def test_failure_never_raises_and_retries_same_occurrence
    ids = []
    Blackbox.client.config.transport = ->(_path, json) { ids << JSON.parse(json)['occurrence_id']; raise 'unavailable' }
    assert Blackbox.notify(RuntimeError.new('synthetic'))
    assert Blackbox.flush
    assert_equal 3, ids.length
    assert_equal 1, ids.uniq.length
    assert_equal 1, Blackbox.client.stats[:dropped]
  end
  def test_invalid_credentials_are_not_retried
    calls = 0
    Blackbox.client.config.transport = ->(*) { calls += 1; 401 }
    Blackbox.notify(RuntimeError.new('synthetic')); Blackbox.flush
    assert_equal 1, calls
  end
  def test_queue_and_flush_are_bounded
    gate = Queue.new
    Blackbox.client.config.transport = ->(*) { gate.pop; 202 }
    150.times { Blackbox.notify(RuntimeError.new('synthetic')) }
    assert_operator Blackbox.client.stats[:pending], :<=, 101
    refute Blackbox.flush(timeout: 0.01)
    assert_operator Blackbox.client.stats[:dropped], :>, 0
  end
  def test_filter_failure_does_not_break_application
    Blackbox.client.config.filters << ->(*) { raise 'bad filter' }
    refute Blackbox.notify(RuntimeError.new('synthetic'))
  end
  def test_expected_error_context_is_limited_to_the_current_request
    Blackbox.client.config.filters << Blackbox::ShieldFilter
    Blackbox.with_context(component: 'rack') do
      Blackbox.merge_context(ignore_error: true)
      refute Blackbox.notify(RuntimeError.new('expected DNS error'))
    end
    Blackbox.merge_context(ignore_error: true)
    assert Blackbox.notify(RuntimeError.new('unexpected failure'))
    assert Blackbox.flush
    assert_equal 1, @sent.size
  end
  def test_rack_preserves_exception
    error = RuntimeError.new('synthetic')
    app = Blackbox::RackMiddleware.new(->(*) { raise error })
    raised = assert_raises(RuntimeError) { app.call('REQUEST_METHOD' => 'GET', 'PATH_INFO' => '/path') }
    assert_same error, raised
    Blackbox.flush
    assert_equal 1, @sent.size
  end
  def test_sidekiq_wait_errors_report_only_final_retry
    Blackbox.client.config.job_adapter = :sidekiq
    Blackbox.client.config.filters << Blackbox::ShieldFilter
    Blackbox.client.config.retriable_wait = ->(*) { true }
    middleware = Blackbox::SidekiqMiddleware.new
    [nil, 0, 1].each do |count|
      assert_raises(RuntimeError) { middleware.call(nil, { 'class' => 'WaitJob', 'retry' => 2, 'retry_count' => count }, 'default') { raise 'waiting' } }
    end
    Blackbox.flush
    assert_equal 1, @sent.size
  end
  def test_fork_reinitializes_delivery_state
    skip 'fork unavailable' unless Process.respond_to?(:fork)
    reader, writer = IO.pipe
    pid = fork do
      reader.close
      Blackbox.client.config.transport = ->(*) { 202 }
      result = Blackbox.notify(RuntimeError.new('child')) && Blackbox.flush(timeout: 1)
      writer.write(result.to_s); writer.close; exit! 0
    end
    writer.close; assert_equal 'true', reader.read; reader.close; Process.wait(pid)
  end
end
