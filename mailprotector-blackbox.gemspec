require_relative 'lib/blackbox/version'
Gem::Specification.new do |s|
  s.name = 'mailprotector-blackbox'
  s.version = Blackbox::VERSION
  s.summary = 'Bounded exception reporting for Mailprotector Blackbox'
  s.homepage = 'https://github.com/mailprotector/blackbox-ruby'
  s.authors = ['Mailprotector']
  s.license = 'Nonstandard'
  s.required_ruby_version = '>= 2.7'
  s.files = Dir['lib/**/*.rb']
  s.require_paths = ['lib']
  s.metadata['allowed_push_host'] = 'https://packages.invalid'
end
