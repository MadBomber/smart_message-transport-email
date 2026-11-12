# frozen_string_literal: true

require "net/imap"

module SmartMessage
  module Transport
    module Email
      # Reads SmartMessage emails from an IMAP mailbox.
      #
      # Only unread mail whose X-SmartMessage-Class header names a wanted
      # message class is fetched.  Fetching uses BODY.PEEK so an email stays
      # unread until the caller acknowledges it, and only acknowledged mail
      # is marked read or deleted.  Each call opens and closes its own
      # connection.
      class ImapReader
        FETCH_BATCH = 50

        attr_reader :address, :port, :mailbox, :after_receive

        def initialize(address: nil, port: 993, user_name: nil, password: nil, ssl: true,
                       mailbox: "INBOX", after_receive: :mark_read, logger: nil)
          @address       = address
          @port          = port
          @user_name     = user_name
          @password      = password
          @ssl           = ssl
          @mailbox       = mailbox
          @after_receive = after_receive
          @logger        = logger
        end

        # Yield the raw RFC 822 text of each unread email for the given
        # message classes.  The email is acknowledged when the block
        # returns true.
        #
        # @param class_names [Array<String>]
        # @yieldparam raw [String]
        # @yieldreturn [Boolean] acknowledge this email
        def each_message(class_names)
          if @address.nil?
            raise SmartMessage::Errors::TransportError,
                  "the email transport needs imap: { address: } to subscribe"
          end

          with_mailbox do |imap|
            acknowledged = []

            uids_for(imap, class_names).each_slice(FETCH_BATCH) do |batch|
              Array(imap.uid_fetch(batch, ["UID", "BODY.PEEK[]"])).each do |data|
                acknowledged << data.attr["UID"] if yield(data.attr["BODY[]"])
              end
            end

            acknowledge(imap, acknowledged)
          end
        end

        private

        def uids_for(imap, class_names)
          class_names.flat_map do |name|
            imap.uid_search(["UNSEEN", "HEADER", SmartMessage::Transport::EmailTransport::CLASS_HEADER, name])
          end.uniq.sort
        end

        def acknowledge(imap, uids)
          return if uids.empty?

          if @after_receive == :delete
            imap.uid_store(uids, "+FLAGS", [:Deleted])
            imap.expunge
          else
            imap.uid_store(uids, "+FLAGS", [:Seen])
          end
        end

        def open_connection
          Net::IMAP.new(@address, port: @port, ssl: @ssl)
        end

        def with_mailbox
          imap = open_connection
          imap.login(@user_name, @password) if @user_name
          imap.select(@mailbox)
          yield imap
        rescue Net::IMAP::Error, IOError, SystemCallError, OpenSSL::SSL::SSLError => e
          raise SmartMessage::Errors::TransportError, "IMAP #{@address}:#{@port}: #{e.class.name} - #{e.message}"
        ensure
          close_quietly(imap)
        end

        def close_quietly(imap)
          return if imap.nil? || imap.disconnected?

          imap.logout
          imap.disconnect
        rescue StandardError => e
          @logger&.debug { "[#{self.class.name}] IMAP logout failed: #{e.class.name} - #{e.message}" }
        end
      end
    end
  end
end
