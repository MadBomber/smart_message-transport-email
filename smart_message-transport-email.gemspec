# frozen_string_literal: true

require_relative "lib/smart_message/transport/email/version"

Gem::Specification.new do |spec|
  spec.name = "smart_message-transport-email"
  spec.version = SmartMessage::Transport::Email::VERSION
  spec.authors = ["Dewayne VanHoozer"]
  spec.email = ["dewayne@vanhoozer.me"]

  spec.summary = "Email (SMTP/IMAP) transport for SmartMessage"
  spec.description = "A SmartMessage transport that publishes messages as emails through any Mail " \
                     "delivery method (SMTP, sendmail, file) and receives them by polling an IMAP mailbox."
  spec.homepage = "https://github.com/MadBomber/smart_message-transport-email"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 4.0"
  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/MadBomber/smart_message-transport-email"
  spec.metadata["changelog_uri"] = "https://github.com/MadBomber/smart_message-transport-email/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile .gitignore test/ .rubocop.yml])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "mail", "~> 2.8"
  spec.add_dependency "net-imap", ">= 0.4"
  spec.add_dependency "smart_message", ">= 0.0.18"

  # For more information and examples about making a new gem, check out our
  # guide at: https://guides.rubygems.org/make-your-own-gem/
end
