import Foundation
import Plugin
import Structure

public enum ReferenceSlackConnectorDraft {
    static func make(
        scope: PluginFactoryCreateInput.ConnectorScope,
        userGoal: String?
    ) -> PluginFactoryDraft {
        _ = scope
        return fullSync(userGoal: userGoal)
    }

    private static func fullSync(userGoal: String?) -> PluginFactoryDraft {
        draft(
            ops: ["sync_threads", "poll_inbox", "send_message"],
            testInput: """
            {"hops":[
              {"kind":"manual","params":{"messaging_op":"sync_threads"}},
              {"kind":"http_results","http_results":[{"request_id":"sync-1","status":200,"body":"{\\"ok\\":true,\\"channels\\":[{\\"id\\":\\"C123\\",\\"name\\":\\"general\\",\\"is_member\\":true},{\\"id\\":\\"C999\\",\\"name\\":\\"secret\\",\\"is_member\\":false}],\\"response_metadata\\":{\\"next_cursor\\":\\"\\"}}"}],"params":{"messaging_op":"sync_threads"}},
              {"kind":"manual","params":{"messaging_op":"poll_inbox","vendor_thread_id":"C123"}},
              {"kind":"http_results","http_results":[{"request_id":"poll-1","status":200,"body":"{\\"ok\\":true,\\"messages\\":[{\\"type\\":\\"message\\",\\"user\\":\\"U1\\",\\"text\\":\\"hello\\",\\"ts\\":\\"1710000000.000100\\",\\"channel\\":\\"C123\\",\\"reply_count\\":1,\\"thread_ts\\":\\"1710000000.000100\\"}]}"}],"params":{"messaging_op":"poll_inbox","vendor_thread_id":"C123"}},
              {"kind":"manual","params":{"messaging_op":"poll_inbox","vendor_thread_id":"C123","parent_vendor_message_id":"1710000000.000100"}},
              {"kind":"http_results","http_results":[{"request_id":"replies-1","status":200,"body":"{\\"ok\\":true,\\"messages\\":[{\\"type\\":\\"message\\",\\"user\\":\\"U1\\",\\"text\\":\\"hello\\",\\"ts\\":\\"1710000000.000100\\",\\"thread_ts\\":\\"1710000000.000100\\",\\"reply_count\\":1},{\\"type\\":\\"message\\",\\"user\\":\\"U2\\",\\"text\\":\\"hi this is a thread\\",\\"ts\\":\\"1710000002.000100\\",\\"thread_ts\\":\\"1710000000.000100\\"}]}"}],"params":{"messaging_op":"poll_inbox","vendor_thread_id":"C123","parent_vendor_message_id":"1710000000.000100"}},
              {"kind":"message_in_room","params":{"messaging_op":"send_message","vendor_thread_id":"C123","text":"hello"}},
              {"kind":"http_results","http_results":[{"request_id":"send-1","status":200,"body":"{\\"ok\\":true,\\"channel\\":\\"C123\\",\\"ts\\":\\"1710000001.000100\\",\\"message\\":{\\"text\\":\\"hello\\"}}"}],"params":{"messaging_op":"send_message","vendor_thread_id":"C123","text":"hello"}}
            ]}
            """,
            source: fullSyncSource,
            userGoal: userGoal
        )
    }

    private static func draft(
        ops: [String],
        testInput: String,
        source: String,
        userGoal: String?
    ) -> PluginFactoryDraft {
        let opsJSON = ops.map { "\"\($0)\"" }.joined(separator: ", ")
        let manifestJSON = """
        {"$schema":"\(PluginContract.agentPluginSchema)","name":"slack-connection","version":"1.0.0",\
        "description":"Slack messaging connector",\
        "extensions":{"app.derrick":{"entrypoint":"./app.derrick/plugin.py","role":"connector","auth_scheme":"bot_token","secrets":[{"id":"bot_token","label":"Bot Token","kind":"token"}],"permissions":["channels:history","channels:read","chat:write","groups:history","groups:read","im:history","im:read","mpim:history","mpim:read","users:read"],"messaging_ops":[\(opsJSON)]}}}
        """
        return PluginFactoryDraft(
            manifestJSON: manifestJSON,
            guestSource: source,
            testInput: Data(testInput.utf8),
            userGoal: userGoal
        )
    }

    private static let fullSyncSource = """
    import json, sys
    def emit(x): json.dump(x, sys.stdout, separators=(",", ":"))
    def sorted_results(results):
        seen = set()
        out = []
        for item in sorted(results or [], key=lambda r: str(r.get("request_id",""))):
            rid = str(item.get("request_id",""))
            if rid and rid not in seen:
                seen.add(rid)
                out.append(item)
        return out
    def message_from(msg, default_channel):
        if not isinstance(msg, dict): return None
        channel = msg.get("channel") or default_channel
        ts = msg.get("ts")
        if not channel or not ts: return None
        thread_ts = msg.get("thread_ts")
        parent = None
        if thread_ts and str(thread_ts) != str(ts):
            parent = str(thread_ts)
        reply_count = int(msg.get("reply_count") or 0)
        row = {"vendor_thread_id":channel,"vendor_message_id":str(ts),"direction":"inbound","sender":msg.get("user") or "slack","body":msg.get("text") or "","created_at":str(ts),"reply_count":reply_count}
        if parent:
            row["parent_vendor_message_id"] = parent
        return row
    def main():
        event = json.load(sys.stdin)
        params = event.get("params") or {}
        op = params.get("messaging_op")
        if event.get("kind") == "manual" and op == "sync_threads":
            emit([{"verb":"http.request","request_id":"sync-1","method":"GET","url":"https://slack.com/api/conversations.list?types=public_channel,private_channel&limit=200&exclude_archived=true","headers":{"Authorization":"Bearer {{secret:bot_token}}"}}])
            return
        if event.get("kind") == "manual" and op == "poll_inbox":
            channel = params.get("vendor_thread_id") or params.get("channel")
            parent = params.get("parent_vendor_message_id") or params.get("thread_ts")
            if not channel:
                emit([{"verb":"result.emit","messages":[]}])
                return
            if parent:
                url = "https://slack.com/api/conversations.replies?channel=" + str(channel) + "&ts=" + str(parent) + "&limit=50"
                emit([{"verb":"http.request","request_id":"replies-1","method":"GET","url":url,"headers":{"Authorization":"Bearer {{secret:bot_token}}"}}])
                return
            url = "https://slack.com/api/conversations.history?channel=" + str(channel) + "&limit=50"
            emit([{"verb":"http.request","request_id":"poll-1","method":"GET","url":url,"headers":{"Authorization":"Bearer {{secret:bot_token}}"}}])
            return
        if event.get("kind") == "message_in_room" and op == "send_message":
            channel = params.get("vendor_thread_id")
            text = params.get("text", "")
            parent = params.get("parent_vendor_message_id") or params.get("thread_ts")
            payload = {"channel":channel,"text":text}
            if parent:
                payload["thread_ts"] = parent
            emit([{"verb":"http.request","request_id":"send-1","method":"POST","url":"https://slack.com/api/chat.postMessage","headers":{"Authorization":"Bearer {{secret:bot_token}}","Content-Type":"application/json"},"json":payload}])
            return
        if event.get("kind") == "http_results" and op == "sync_threads":
            threads = []
            for item in sorted_results(event.get("http_results")):
                if item.get("request_id") != "sync-1": continue
                payload = json.loads(item.get("body") or "{}")
                if payload.get("ok") is False:
                    emit([{"verb":"result.emit","title":"Slack list failed","summary":str(payload.get("error") or "unknown")}])
                    return
                for ch in sorted(payload.get("channels") or [], key=lambda c: str(c.get("id",""))):
                    if ch.get("is_member") is False:
                        continue
                    cid = ch.get("id")
                    name = ch.get("name") or cid
                    if cid:
                        threads.append({"vendor_thread_id":cid,"title":"#" + str(name)})
            emit([{"verb":"result.emit","threads":threads}])
            return
        if event.get("kind") == "http_results" and op == "poll_inbox":
            channel = params.get("vendor_thread_id") or params.get("channel")
            messages = []
            for item in sorted_results(event.get("http_results")):
                if item.get("request_id") not in ("poll-1", "replies-1"): continue
                payload = json.loads(item.get("body") or "{}")
                if payload.get("ok") is False:
                    emit([{"verb":"result.emit","title":"Slack blocked this thread","summary":str(payload.get("error") or "unknown")}])
                    return
                for msg in sorted(payload.get("messages") or [], key=lambda m: str(m.get("ts",""))):
                    parsed = message_from(msg, channel)
                    if parsed: messages.append(parsed)
            emit([{"verb":"result.emit","messages":messages}])
            return
        if event.get("kind") == "http_results" and op == "send_message":
            body = {}
            for item in sorted_results(event.get("http_results")):
                if item.get("request_id") == "send-1":
                    body = json.loads(item.get("body") or "{}")
            if body.get("ok"):
                ts = body.get("ts") or (body.get("message") or {}).get("ts")
                emit([{"verb":"result.emit","sent_message":{"vendor_message_id":ts,"created_at":ts}}])
            else:
                emit([{"verb":"result.emit","summary":"send failed"}])
            return
        emit([{"verb":"result.emit","summary":"unsupported"}])
    if __name__ == "__main__":
        main()
    """
}
