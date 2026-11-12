# frozen_string_literal: true

require "mail"

module SmartMessage
  module Transport
    # Email transport for SmartMessage.
    #
    # Publishing sends one email per message.  The serialized message is the
    # body, and the X-SmartMessage-Class header names its message class.
    #
    # Subscribing starts one background poller that checks a mailbox for
    # unread mail carrying that header, hands each payload to the dispatcher,
    # and then marks the email read (or deletes it).  Mail for a message
    # class with no handlers in this process is left unread for someone else.
    #
    # == Delivery semantics: at least once, slow
    #
    # A message stays in the mailbox until a subscriber takes it, so a
    # subscriber that is down when it is sent still gets it later.  An email
    # is acknowledged after it is handed to the dispatcher; a crash between
    # the two delivers it again.  Latency is the mail system's plus up to
    # one poll_interval.  When several processes poll one mailbox, one
    # process may take a message before another sees it, so give each
    # subscribing process its own mailbox when every one must get a copy.
    #
    # Options:
    #   from:              sender address.  Required to publish.
    #   to:                recipient address (String or Array) for every
    #                      message class without a route.
    #   routes:            { "ClassName" => address(es) } per message class
    #   subject_prefix:    subject is "#{subject_prefix} ClassName"
    #                      (default "[SmartMessage]")
    #   delivery_method:   any Mail delivery method: :smtp (default),
    #                      :sendmail, :file, :test, ...
    #   delivery_settings: settings for that method, e.g. for :smtp
    #                      { address:, port:, user_name:, password:,
    #                        authentication:, enable_starttls_auto: }
    #   imap:              { address:, port: 993, user_name:, password:,
    #                        ssl: true } for the mailbox subscribers poll
    #   mailbox:           IMAP folder to poll (default "INBOX")
    #   after_receive:     :mark_read (default) or :delete
    #   poll_interval:     seconds between mailbox checks (default 30)
    #   reader:            an object that replaces the IMAP reader; it
    #                      responds to #each_message(class_names) { |raw| }
    #                      and acknowledges a message when the block
    #                      returns true
    class EmailTransport < Base
      CLASS_HEADER   = "X-SmartMessage-Class"
      VERSION_HEADER = "X-SmartMessage-Version"
      AFTER_RECEIVE  = %i[mark_read delete].freeze

      def default_options
        {
          from: nil,
          to: nil,
          routes: {},
          subject_prefix: "[SmartMessage]",
          delivery_method: :smtp,
          delivery_settings: {},
          imap: {},
          mailbox: "INBOX",
          after_receive: :mark_read,
          poll_interval: 30
        }
      end

      def configure
        unless AFTER_RECEIVE.include?(@options[:after_receive])
          raise ArgumentError, "after_receive: must be one of #{AFTER_RECEIVE.inspect}"
        end

        @reader      = @options[:reader]
        @state_mutex = Mutex.new
        @poll_mutex  = Mutex.new
        @poller      = nil
        @wakeup      = nil
        @closed      = false
      end

      # The addresses mail for a message class is sent to
      # @return [Array<String>]
      def recipients_for(message_class)
        routes = @options[:routes] || {}
        Array(routes[message_class.to_s] || routes[message_class.to_s.to_sym] || @options[:to]).compact
      end

      # Build the email that carries one serialized message.
      # @return [Mail::Message]
      def build_mail(message_class, serialized_message)
        if @options[:from].nil?
          raise SmartMessage::Errors::TransportError,
                "#{self.class.name} needs a from: address to publish"
        end

        recipients = recipients_for(message_class)
        if recipients.empty?
          raise SmartMessage::Errors::TransportError,
                "#{self.class.name} has no recipient for #{message_class}; set to: or routes:"
        end

        mail         = Mail.new
        mail.from    = @options[:from]
        mail.to      = recipients
        mail.subject = "#{@options[:subject_prefix]} #{message_class}".strip
        mail[CLASS_HEADER]   = message_class.to_s
        mail[VERSION_HEADER] = SmartMessage::VERSION
        attach_payload(mail, serialized_message)
        mail
      end

      def do_publish(message_class, serialized_message)
        raise SmartMessage::Errors::TransportError, "#{self.class.name} is disconnected" if closed?

        mail = build_mail(message_class, serialized_message)
        mail.delivery_method(@options[:delivery_method], @options[:delivery_settings] || {})
        mail.deliver!
        logger.debug { "[#{self.class.name}] Emailed #{message_class} to #{mail.to.join(", ")}" }
      end

      def subscribe(message_class, process_method, filter_options = {})
        raise SmartMessage::Errors::TransportError, "#{self.class.name} is disconnected" if closed?

        super
        start_poller
      end

      def unsubscribe(message_class, process_method)
        super
        stop_poller if subscribers.empty?
      end

      def unsubscribe!(message_class)
        super
        stop_poller if subscribers.empty?
      end

      # Check the mailbox once, now, and deliver what is there.
      # The poller calls this every poll_interval.
      # @return [Integer] the number of emails handed to the dispatcher
      def poll
        class_names = subscribers.select { |_name, subs| subs.any? }.keys
        return 0 if class_names.empty?

        delivered = 0
        reader.each_message(class_names) do |raw|
          handled = deliver_email(raw, class_names)
          delivered += 1 if handled
          handled
        end
        delivered
      end

      # The mailbox reader: the reader: option, else an ImapReader built
      # from the imap: options
      def reader
        @reader ||= Email::ImapReader.new(
          **(@options[:imap] || {}),
          mailbox: @options[:mailbox],
          after_receive: @options[:after_receive],
          logger: logger
        )
      end

      def connected?
        !closed?
      end

      def connect
        @state_mutex.synchronize { @closed = false }
        start_poller unless subscribers.empty?
      end

      # Stop the poller and close the mailbox connection.
      # Safe to call more than once.
      def disconnect
        stop_poller
        @state_mutex.synchronize { @closed = true }
        @reader.close if @reader.respond_to?(:close)
      end

      # Pull the serialized message back out of an email.
      # @param mail [Mail::Message]
      # @return [String]
      def self.payload_of(mail)
        body = mail.body.decoded
        mail.mime_type == "application/octet-stream" ? body.b : body.dup.force_encoding(Encoding::UTF_8)
      end

      private

      def closed?
        @state_mutex.synchronize { @closed }
      end

      # Text payloads (JSON) stay readable in a mail client; anything else
      # (MessagePack, for one) travels as base64.
      def attach_payload(mail, serialized_message)
        text = serialized_message.dup.force_encoding(Encoding::UTF_8)

        if text.valid_encoding?
          mail.content_type = "text/plain; charset=UTF-8"
          mail.body         = text
        else
          # Mail picks base64 for binary content on its own
          mail.content_type = "application/octet-stream"
          mail.body         = serialized_message.b
        end
      end

      # @return [Boolean] true when the email should be acknowledged
      def deliver_email(raw, class_names)
        mail          = Mail.new(raw)
        message_class = mail[CLASS_HEADER]&.value.to_s.strip

        # IMAP header search matches substrings; take only exact matches.
        return false unless class_names.include?(message_class)

        begin
          receive(message_class, self.class.payload_of(mail))
        rescue StandardError => e
          # #receive has logged it and stored undecodable payloads in the
          # dead letter queue; acknowledge so it is not retried forever.
          logger.debug { "[#{self.class.name}] Skipped an email for #{message_class}: #{e.class.name}" }
        end
        true
      end

      def start_poller
        @poll_mutex.synchronize do
          return if @poller&.alive?

          @wakeup = Queue.new
          wakeup  = @wakeup
          @poller = Thread.new { poll_loop(wakeup) }
          @poller.name = "SmartMessage-EmailPoller"
        end
      end

      def stop_poller
        poller = @poll_mutex.synchronize do
          thread  = @poller
          @poller = nil
          @wakeup&.push(:stop)
          thread
        end
        return if poller.nil? || poller == Thread.current

        poller.join(5) || poller.kill
      end

      # Poll until told to stop.  The Queue doubles as the sleep timer, so
      # stopping does not wait out a poll interval.
      def poll_loop(wakeup)
        loop do
          begin
            poll
          rescue StandardError => e
            logger.error { "[#{self.class.name}] Mailbox check failed: #{e.class.name} - #{e.message}" }
          end
          break if wakeup.pop(timeout: @options[:poll_interval]) == :stop
        end
      end
    end
  end
end
