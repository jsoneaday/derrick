import Foundation

/// Host ↔ connector plugin contract for Messaging sync, poll, and send.
public enum ConnectorMessagingContract: Sendable {
    public static let hostContract = """
    Connector messaging host contract (all connector plugins with role: connector):
    - The host calls plugin.invoke with a hop event whose params.messaging_op is one of:
      sync_threads, poll_inbox, send_message.
    - sync_threads and poll_inbox use kind "manual". send_message uses kind "message_in_room".
    - Read params.messaging_op and extra params (vendor_thread_id, text, since/oldest for incremental poll_inbox).
    - For poll_inbox the host passes vendor_thread_id for each open thread row it is listening to.
    - On the first poll for a thread (no inbound cursor yet), the host passes since/oldest from when the user opened the connector (listening_since) so vendor history is not imported wholesale.
    - Bootstrap sync_threads only; poll_inbox runs on the background ingress loop, not during bootstrap open.
    - Emit http.request envelopes for vendor HTTP; on http_results emit a terminal result.emit.
    - `http_results` is a JSON array of `{request_id, status, headers, body}` objects.
      Index by `request_id` before lookup (do not assume a map).
    - sync_threads lists only conversations the saved secret can access (membership, join, or equivalent).
      Do not emit public rooms the credential is not in. If the vendor marks membership (Slack is_member),
      skip entries where that flag is false. Treat a missing flag as accessible so tests without it still work.
      Emit threads: [{vendor_thread_id, title}] where title is the human label shown in the host UI
      and vendor_thread_id is what send_message and poll_inbox use. Optional accessible/is_member false
      is dropped by the host even if the plugin emits it.
    - When the vendor uses opaque IDs (Slack channel IDs, Telegram chat IDs, etc.), sync_threads is required so users
      pick conversations by name instead of typing vendor IDs.
    - result.emit payload must include structured fields the host persists:
      messages: [{vendor_thread_id, vendor_message_id, direction, sender, body, created_at}]
      sent_message (send_message only): {vendor_message_id, created_at}
    - direction must be "inbound" or "outbound".
    - created_at may be a Unix timestamp string (Slack ts) or ISO-8601.
      For outbound messages from this connector, use direction "outbound".
    - Paginate vendor list/history APIs; merge pages before returning threads/messages.
    - Never embed secrets in python_source; use host HTTP with attached Keychain secrets.
    - Connector manifests must declare extensions.app.derrick.messaging_ops listing every implemented op.
    """
}
