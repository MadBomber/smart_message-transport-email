## [Unreleased]

## [0.1.0] - 2026-11-11

- `SmartMessage::Transport::EmailTransport`, registered as `:email`
- Publishes each message as one email through any Mail delivery method (`:smtp`, `:sendmail`, `:file`, `:test`)
- Receives by polling an IMAP mailbox for unread mail with an `X-SmartMessage-Class` header naming a subscribed class
- Per-class recipients through `routes:`; acknowledged mail is marked read or deleted (`after_receive:`)
- Text payloads (JSON) travel as `text/plain`; binary payloads (MessagePack) as base64 `application/octet-stream`
