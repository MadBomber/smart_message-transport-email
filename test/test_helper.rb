# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "tmpdir"
require "fileutils"
require "smart_message/transport/email"

TEST_RUN_DIR = Dir.mktmpdir("smart_message_email_test")

require "minitest/autorun"

Minitest.after_run { FileUtils.remove_entry(TEST_RUN_DIR) if File.directory?(TEST_RUN_DIR) }

# Plays the part of a mailbox: serves the emails the :test delivery method
# collected, and remembers which ones were acknowledged.
class FakeReader
  attr_reader :acknowledged, :seen

  def initialize
    @acknowledged = []
    @seen         = []
    @mutex        = Mutex.new
  end

  def each_message(class_names)
    @mutex.synchronize { @seen << class_names }
    Mail::TestMailer.deliveries.dup.each do |mail|
      next if @acknowledged.include?(mail)

      @mutex.synchronize { @acknowledged << mail } if yield(mail.to_s)
    end
  end
end

module EmailTestSupport
  def before_setup
    super
    SmartMessage.configuration.reset!
    SmartMessage.configuration.logger   = nil
    SmartMessage.configuration.dlq_path = File.join(TEST_RUN_DIR, "dead_letters.jsonl")
    SmartMessage::Logger.reset!
    SmartMessage::DeadLetterQueue.reset_default!
    SmartMessage::DeadLetterQueue.default.clear
    Mail::TestMailer.deliveries.clear
  end

  def wait_until(timeout: 5, message: "condition was not met in time")
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      flunk("Timed out after #{timeout}s: #{message}") if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.01
    end
    true
  end
end

Minitest::Test.include(EmailTestSupport)
