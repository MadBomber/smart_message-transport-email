# frozen_string_literal: true

require "smart_message"
# When version.rb was loaded first (by the gemspec, under Bundler), it
# defined SmartMessage::Transport, so Zeitwerk never autoloads this file.
require "smart_message/transport" unless SmartMessage::Transport.respond_to?(:register)
require_relative "email/version"
require_relative "email/imap_reader"
require_relative "email_transport"

SmartMessage::Transport.register(:email, SmartMessage::Transport::EmailTransport)
