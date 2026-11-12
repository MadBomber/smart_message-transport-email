# frozen_string_literal: true

require "test_helper"

class ImapReaderTest < Minitest::Test
  FetchData = Struct.new(:attr)

  # Records the IMAP conversation and serves canned mail by UID.
  class FakeImap
    attr_reader :calls

    def initialize(mail_by_class)
      @mail_by_class = mail_by_class
      @calls         = []
      @disconnected  = false
    end

    def login(user, password) = @calls << [:login, user, password]
    def select(mailbox)       = @calls << [:select, mailbox]

    def uid_search(keys)
      @calls << [:uid_search, keys]
      @mail_by_class.fetch(keys.last, {}).keys
    end

    def uid_fetch(uids, attrs)
      @calls << [:uid_fetch, uids, attrs]
      all = @mail_by_class.values.reduce({}, :merge)
      uids.map { |uid| FetchData.new({ "UID" => uid, "BODY[]" => all.fetch(uid) }) }
    end

    def uid_store(uids, op, flags) = @calls << [:uid_store, uids, op, flags]
    def expunge                    = @calls << [:expunge]
    def logout                     = @calls << [:logout]
    def disconnect                 = @disconnected = true
    def disconnected?              = @disconnected
  end

  class TestReader < SmartMessage::Transport::Email::ImapReader
    attr_accessor :fake

    def open_connection = fake
  end

  def reader(after_receive: :mark_read)
    TestReader.new(address: "imap.example.com", user_name: "me", password: "pw",
                   mailbox: "SmartMessage", after_receive: after_receive).tap do |r|
      r.fake = FakeImap.new("A" => { 1 => "raw1", 2 => "raw2" }, "B" => { 3 => "raw3" })
    end
  end

  def test_fetches_unseen_mail_by_class_header_without_marking_it_read
    r    = reader
    seen = []
    r.each_message(%w[A B]) { |raw| seen << raw and false }

    assert_equal %w[raw1 raw2 raw3], seen
    calls = r.fake.calls
    assert_includes calls, [:login, "me", "pw"]
    assert_includes calls, [:select, "SmartMessage"]
    assert_includes calls, [:uid_search, %w[UNSEEN HEADER X-SmartMessage-Class A]]
    assert_includes calls, [:uid_fetch, [1, 2, 3], ["UID", "BODY.PEEK[]"]]
    refute(calls.any? { |call| call.first == :uid_store })
    assert r.fake.disconnected?
  end

  def test_marks_acknowledged_mail_read
    r = reader
    r.each_message(%w[A B]) { |raw| raw != "raw2" }

    assert_includes r.fake.calls, [:uid_store, [1, 3], "+FLAGS", [:Seen]]
  end

  def test_deletes_acknowledged_mail_when_asked
    r = reader(after_receive: :delete)
    r.each_message(%w[A]) { |_raw| true }

    assert_includes r.fake.calls, [:uid_store, [1, 2], "+FLAGS", [:Deleted]]
    assert_includes r.fake.calls, [:expunge]
  end

  def test_requires_an_address
    assert_raises(SmartMessage::Errors::TransportError) do
      SmartMessage::Transport::Email::ImapReader.new.each_message(%w[A]) { true }
    end
  end
end
