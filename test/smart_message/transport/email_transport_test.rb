# frozen_string_literal: true

require "test_helper"

module EmailTransportTest
  class OrderMessage < SmartMessage::Base
    from "order-service"

    property :order_id
    property :amount
  end

  class AlertMessage < SmartMessage::Base
    from "alert-service"

    property :text
  end

  class Test < Minitest::Test
    def setup
      @reader    = FakeReader.new
      @transport = build_transport
      [OrderMessage, AlertMessage].each { |klass| klass.transport(@transport) }
    end

    def teardown
      [OrderMessage, AlertMessage].each do |klass|
        klass.unsubscribe!
        klass.reset_transport
      end
      @transport.disconnect
    end

    def build_transport(**)
      SmartMessage::Transport::EmailTransport.new(
        from: "sender@example.com",
        to: "inbox@example.com",
        delivery_method: :test,
        reader: @reader,
        poll_interval: 0.05,
        **
      )
    end

    def test_registers_as_email
      assert_equal SmartMessage::Transport::EmailTransport, SmartMessage::Transport.get(:email)
    end

    def test_publish_sends_one_email_per_message
      OrderMessage.new(order_id: "A1", amount: 9.5).publish

      assert_equal 1, Mail::TestMailer.deliveries.size
      mail = Mail::TestMailer.deliveries.first
      assert_equal ["sender@example.com"], mail.from
      assert_equal ["inbox@example.com"], mail.to
      assert_equal "[SmartMessage] EmailTransportTest::OrderMessage", mail.subject
      assert_equal "EmailTransportTest::OrderMessage", mail[SmartMessage::Transport::EmailTransport::CLASS_HEADER].value
      assert_includes mail.body.decoded, '"order_id":"A1"'
    end

    def test_routes_choose_recipients_per_message_class
      transport = build_transport(routes: { "EmailTransportTest::AlertMessage" => %w[ops@example.com
                                                                                     oncall@example.com] })

      assert_equal %w[ops@example.com oncall@example.com], transport.recipients_for("EmailTransportTest::AlertMessage")
      assert_equal ["inbox@example.com"], transport.recipients_for("EmailTransportTest::OrderMessage")
    end

    def test_publish_without_from_or_recipient_raises
      no_from = build_transport(from: nil)
      no_to   = build_transport(to: nil)

      assert_raises(SmartMessage::Errors::TransportError) { no_from.do_publish("X", "{}") }
      assert_raises(SmartMessage::Errors::TransportError) { no_to.do_publish("X", "{}") }
    end

    def test_publish_after_disconnect_raises
      @transport.disconnect

      refute @transport.connected?
      assert_raises(SmartMessage::Errors::TransportError) { @transport.do_publish("X", "{}") }
    end

    def test_rejects_unknown_after_receive
      assert_raises(ArgumentError) { build_transport(after_receive: :archive) }
    end

    def test_binary_payload_survives_the_trip
      payload = "\x82\xA1a\x01\xFF\x00".b
      mail    = Mail.new(@transport.build_mail("X", payload).to_s)

      assert_equal "application/octet-stream", mail.mime_type
      assert_equal payload, SmartMessage::Transport::EmailTransport.payload_of(mail)
    end

    def test_long_text_payload_survives_the_trip
      payload = %({"text":"#{"é" * 2000}"})
      mail    = Mail.new(@transport.build_mail("X", payload).to_s)

      assert_equal payload, SmartMessage::Transport::EmailTransport.payload_of(mail)
    end

    def test_poll_delivers_subscribed_mail_and_acknowledges_it
      received = Queue.new
      OrderMessage.subscribe { |message| received << message }
      OrderMessage.new(order_id: "A1", amount: 9.5).publish

      assert_equal 1, @transport.poll

      message = received.pop(timeout: 5)
      assert_equal "A1", message.order_id
      assert_in_delta 9.5, message.amount
      assert_equal 1, @reader.acknowledged.size
      assert_equal [["EmailTransportTest::OrderMessage"]], @reader.seen.uniq
    end

    def test_poll_leaves_mail_for_unsubscribed_classes
      OrderMessage.subscribe { |_message| nil }
      AlertMessage.new(text: "disk full").publish

      assert_equal 0, @transport.poll
      assert_empty @reader.acknowledged
    end

    def test_poll_without_subscriptions_does_not_read_the_mailbox
      assert_equal 0, @transport.poll
      assert_empty @reader.seen
    end

    def test_undecodable_mail_is_dead_lettered_and_acknowledged
      OrderMessage.subscribe { |_message| nil }
      @transport.do_publish("EmailTransportTest::OrderMessage", "not json")

      assert_equal 1, @transport.poll
      assert_equal 1, @reader.acknowledged.size
      assert_equal 1, SmartMessage::DeadLetterQueue.default.size
    end

    def test_poller_delivers_in_the_background_and_stops_on_unsubscribe
      received = Queue.new
      handler  = OrderMessage.subscribe { |message| received << message }
      OrderMessage.new(order_id: "B2", amount: 1).publish

      assert_equal "B2", received.pop(timeout: 5)&.order_id

      OrderMessage.unsubscribe(handler)
      poller = @transport.instance_variable_get(:@poller)
      assert_nil poller
    end
  end
end
