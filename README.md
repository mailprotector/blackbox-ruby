# Blackbox for Ruby

Mailprotector's Ruby exception reporter for Blackbox. Install the tagged release through Bundler.

```ruby
gem 'mailprotector-blackbox', git: 'https://github.com/mailprotector/blackbox-ruby.git', tag: 'v0.1.0', require: 'blackbox'
```

Set `BLACKBOX_INGEST_KEY` to the key scoped to your application and environment. Reporting is opt-in. The default destination is `https://blackbox.mailprotector.dev`. Set `BLACKBOX_ENDPOINT` to another HTTPS origin for a specific deployment.

```ruby
require 'blackbox'
Blackbox.configure do |config|
  config.project = 'myapp'
  config.environment = ENV.fetch('APP_ENV')
  config.token = ENV['BLACKBOX_INGEST_KEY']
  config.enabled = ENV['BLACKBOX_ENABLED'] == 'true'
end
Blackbox.notify(error)
```

The reporter includes Rack, Rails, Active Job, Sidekiq and Shoryuken integrations. Choose one job adapter per worker. Flush pending reports with `Blackbox.shutdown(timeout: 3)` at process exit.

Run `ruby -Ilib test/client_test.rb` for the client tests. The Rails and Sidekiq checks run in CI.
