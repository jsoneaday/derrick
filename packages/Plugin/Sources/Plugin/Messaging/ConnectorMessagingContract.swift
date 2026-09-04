import Foundation

/// Host ↔ connector plugin contract for Messaging sync, poll, and send.
public enum ConnectorMessagingContract: Sendable {
    public static let hostContract = """
    Connector messaging host contract (all connector plugins with role: connector):
    - The host calls plugin.invoke with a hop event whose params.messaging_op is one of:
      sync_threads, poll_inbox, send_message.
    - sync_threads and poll_inbox use kind "manual". send_message uses kind "message_in_room".
    - Read params.messaging_op and any extra params (vendor_thread_id, text).
    - Emit http.request envelopes for vendor HTTP; on http_results emit a terminal result.emit.
    - `http_results` is a JSON array of `{request_id, status, headers, body}` objects.
      Index by `request_id` before lookup (do not assume a map).
    - result.emit payload must include structured fields the host persists:
      threads: [{vendor_thread_id, title}]
      messages: [{vendor_thread_id, vendor_message_id, direction, sender, body, created_at}]
      sent_message (send_message only): {vendor_message_id, created_at}
    - direction must be "inbound" or "outbound".
    - created_at may be a Unix timestamp string (Slack ts) or ISO-8601.
      For outbound messages from this connector, use direction "outbound".
    - Paginate vendor list/history APIs; merge pages before returning threads/messages.
    - Never embed secrets in python_source; use host HTTP with attached Keychain secrets.
    """
}
