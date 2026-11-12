# SmartMessage::Transport::Email

An email transport for [SmartMessage](https://github.com/MadBomber/smart_message). Publishing sends each message as one email through any [Mail](https://github.com/mikel/mail) delivery method (SMTP, sendmail, file). Subscribing polls an IMAP mailbox for those emails and routes them to your handlers.

Email is slow and durable. Use it to reach processes that are offline, behind firewalls, or run by people who only share a mail server with you. It is not for low-latency traffic.

## Installation

```bash
bundle add smart_message-transport-email
```

Requires Ruby 4.0 or later and `smart_message`.

## Usage

```ruby
require "smart_message/transport/email"

transport = SmartMessage::Transport.create(
  :email,
  from: "orders@example.com",
  to:   "smart-message@example.com",
  delivery_method:   :smtp,
  delivery_settings: {
    address: "smtp.example.com", port: 587,
    user_name: ENV["SMTP_USER"], password: ENV["SMTP_PASSWORD"],
    authentication: :plain, enable_starttls_auto: true
  },
  imap: {
    address: "imap.example.com", port: 993, ssl: true,
    user_name: ENV["IMAP_USER"], password: ENV["IMAP_PASSWORD"]
  },
  mailbox:       "INBOX",
  poll_interval: 30
)

class OrderPlaced < SmartMessage::Base
  property :order_id
  property :amount
end

OrderPlaced.transport(transport)

OrderPlaced.subscribe { |message| puts "Order #{message.order_id}: #{message.amount}" }
OrderPlaced.new(order_id: "A-100", amount: 42.0).publish
```

`SmartMessage::Transport::EmailTransport.new(...)` takes the same options.

### What goes over the wire

Each message becomes one email:

- **Subject:** `[SmartMessage] OrderPlaced` (`subject_prefix:` changes the prefix)
- **`X-SmartMessage-Class`:** the message class name; subscribers select mail by this header
- **`X-SmartMessage-Version`:** the SmartMessage version that sent it
- **Body:** the serialized message. Text payloads such as JSON are sent as `text/plain` so they are readable in a mail client. Binary payloads such as MessagePack are sent as base64 `application/octet-stream`.

### Receiving

The first `subscribe` starts one background thread. Every `poll_interval` seconds it opens an IMAP connection, searches the mailbox for unread mail whose `X-SmartMessage-Class` header names a subscribed class, and fetches it with `BODY.PEEK[]`, which leaves the mail unread. Each email it hands to the dispatcher is then acknowledged:

- `after_receive: :mark_read` (default) sets `\Seen`
- `after_receive: :delete` deletes and expunges it

Other mail in the mailbox, including SmartMessage mail for classes this process has not subscribed to, is not changed. An email whose payload cannot be decoded goes to the dead letter queue and is acknowledged, so it is not retried forever.

Call `transport.poll` to check the mailbox right away. It returns the number of emails it delivered.

### Delivery semantics

- **At least once.** An email stays in the mailbox until a subscriber takes it, so a subscriber that is down when the message is sent still gets it later. If a process stops after delivering an email but before acknowledging it, the email is delivered again.
- **Slow.** Latency is the mail system's delivery time plus up to one `poll_interval`.
- **Shared mailboxes compete.** When several processes poll one mailbox, whichever polls first takes the message. Give each process its own mailbox (or address) when every one of them must get a copy.
- **Flagged as read by people.** If someone reads the mailbox in a mail client, the mail is marked read and subscribers skip it. Use a dedicated mailbox.

### Options

| Option | Default | Description |
|--------|---------|-------------|
| `from:` | `nil` | Sender address. Required to publish. |
| `to:` | `nil` | Recipient address (String or Array) for message classes without a route. |
| `routes:` | `{}` | `{ "ClassName" => address(es) }`, recipients per message class. |
| `subject_prefix:` | `"[SmartMessage]"` | Subject is `"#{subject_prefix} ClassName"`. |
| `delivery_method:` | `:smtp` | Any Mail delivery method: `:smtp`, `:sendmail`, `:file`, `:test`, ... |
| `delivery_settings:` | `{}` | Settings for that delivery method. |
| `imap:` | `{}` | `address:`, `port:` (993), `ssl:` (true), `user_name:`, `password:`. |
| `mailbox:` | `"INBOX"` | IMAP folder to poll. |
| `after_receive:` | `:mark_read` | `:mark_read` or `:delete`. |
| `poll_interval:` | `30` | Seconds between mailbox checks. |
| `reader:` | IMAP reader | Replaces the IMAP reader. Any object with `each_message(class_names)` that yields each raw email and acknowledges it when the block returns true. |

Publishing raises `SmartMessage::Errors::TransportError` when `from:` or a recipient is missing, or after `disconnect`. SMTP errors are raised as they are, and count toward the transport's circuit breaker.

## Development

The Gemfile uses the `smart_message` core from the sibling directory (`../smart_message`).

```bash
bin/setup
bundle exec rake          # tests and RuboCop
bundle exec rake test     # tests only; no mail server needed
```

Tests publish with Mail's `:test` delivery method and receive through a fake reader, so they need no SMTP or IMAP server.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
