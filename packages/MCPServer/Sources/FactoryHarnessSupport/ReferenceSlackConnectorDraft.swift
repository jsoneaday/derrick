import Foundation
import Plugin
import Structure

public enum ReferenceSlackConnectorDraft {
    static func make(
        scope: PluginFactoryCreateInput.ConnectorScope,
        userGoal: String?
    ) -> PluginFactoryDraft {
        switch scope {
        case .sendOnly:
            return sendOnly(userGoal: userGoal)
        case .sendAndReceive:
            return sendAndReceive(userGoal: userGoal)
        case .fullSync:
            return fullSync(userGoal: userGoal)
        }
    }

    private static func sendOnly(userGoal: String?) -> PluginFactoryDraft {
        draft(
            ops: ["send_message"],
            testInput: """
            {"hops":[
              {"kind":"message_in_room","params":{"messaging_op":"send_message","vendor_thread_id":"C123","text":"hello"}},
              {"kind":"http_results","http_results":[{"request_id":"send-1","status":200,"body":"{\\"ok\\":true,\\"channel\\":\\"C123\\",\\"ts\\":\\"1710000001.000100\\",\\"message\\":{\\"text\\":\\"hello\\"}}"}],"params":{"messaging_op":"send_message","vendor_thread_id":"C123","text":"hello"}}
            ]}
            """,
            source: sendOnlySource,
            userGoal: userGoal
        )
    }

    private static func sendAndReceive(userGoal: String?) -> PluginFactoryDraft {
        draft(
            ops: ["sync_threads", "poll_inbox", "send_message"],
            testInput: """
            {"hops":[
              {"kind":"manual","params":{"messaging_op":"sync_threads"}},
              {"kind":"http_results","http_results":[{"request_id":"sync-1","status":200,"body":"{\\"ok\\":true,\\"channels\\":[{\\"id\\":\\"C123\\",\\"name\\":\\"general\\",\\"is_member\\":true},{\\"id\\":\\"C999\\",\\"name\\":\\"secret\\",\\"is_member\\":false}],\\"response_metadata\\":{\\"next_cursor\\":\\"\\"}}"}],"params":{"messaging_op":"sync_threads"}},
              {"kind":"manual","params":{"messaging_op":"poll_inbox","vendor_thread_id":"C123"}},
              {"kind":"http_results","http_results":[{"request_id":"poll-1","status":200,"body":"{\\"ok\\":true,\\"messages\\":[{\\"type\\":\\"message\\",\\"user\\":\\"U1\\",\\"text\\":\\"hello\\",\\"ts\\":\\"1710000000.000100\\",\\"channel\\":\\"C123\\"}]}"}],"params":{"messaging_op":"poll_inbox","vendor_thread_id":"C123"}},
              {"kind":"message_in_room","params":{"messaging_op":"send_message","vendor_thread_id":"C123","text":"hello"}},
              {"kind":"http_results","http_results":[{"request_id":"send-1","status":200,"body":"{\\"ok\\":true,\\"channel\\":\\"C123\\",\\"ts\\":\\"1710000001.000100\\",\\"message\\":{\\"text\\":\\"hello\\"}}"}],"params":{"messaging_op":"send_message","vendor_thread_id":"C123","text":"hello"}}
            ]}
            """,
            source: sendAndReceiveSource,
            userGoal: userGoal
        )
    }

    private static func fullSync(userGoal: String?) -> PluginFactoryDraft {
        draft(
            ops: ["sync_threads", "poll_inbox", "send_message"],
            testInput: """
            {"hops":[
              {"kind":"manual","params":{"messaging_op":"sync_threads"}},
              {"kind":"http_results","http_results":[{"request_id":"sync-1","status":200,"body":"{\\"ok\\":true,\\"channels\\":[{\\"id\\":\\"C123\\",\\"name\\":\\"general\\",\\"is_member\\":true},{\\"id\\":\\"C999\\",\\"name\\":\\"secret\\",\\"is_member\\":false}],\\"response_metadata\\":{\\"next_cursor\\":\\"\\"}}"}],"params":{"messaging_op":"sync_threads"}},
              {"kind":"manual","params":{"messaging_op":"poll_inbox","vendor_thread_id":"C123"}},
              {"kind":"http_results","http_results":[{"request_id":"poll-1","status":200,"body":"{\\"ok\\":true,\\"messages\\":[{\\"type\\":\\"message\\",\\"user\\":\\"U1\\",\\"text\\":\\"hello\\",\\"ts\\":\\"1710000000.000100\\",\\"channel\\":\\"C123\\"}]}"}],"params":{"messaging_op":"poll_inbox","vendor_thread_id":"C123"}},
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
        "description":"Slack messaging connector","secrets":[{"id":"bot_token","label":"Bot Token","kind":"token"}],\
        "extensions":{"app.derrick":{"entrypoint":"./app.derrick/plugin.py","role":"connector","messaging_ops":[\(opsJSON)]}}}
        """
        return PluginFactoryDraft(
            manifestJSON: manifestJSON,
            guestSource: source,
            testInput: Data(testInput.utf8),
            userGoal: userGoal
        )
    }

    private static let sendOnlySource = """
    import json, sys
    def emit(x): json.dump(x, sys.stdout, separators=(",", ":"))
    def main():
        event = json.load(sys.stdin)
        op = (event.get("params") or {}).get("messaging_op")
        if event.get("kind") == "message_in_room" and op == "send_message":
            channel = (event.get("params") or {}).get("vendor_thread_id")
            text = (event.get("params") or {}).get("text", "")
            emit([{"verb":"http.request","request_id":"send-1","method":"POST","url":"https://slack.com/api/chat.postMessage","headers":{"Authorization":"Bearer {{secret:bot_token}}","Content-Type":"application/json"},"body":json.dumps({"channel":channel,"text":text}, separators=(",", ":"))}])
            return
        if event.get("kind") == "http_results" and op == "send_message":
            body = {}
            for item in sorted(event.get("http_results") or [], key=lambda r: str(r.get("request_id",""))):
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

    private static let sendAndReceiveSource = """
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
        return {"vendor_thread_id":channel,"vendor_message_id":ts,"direction":"inbound","sender":msg.get("user") or "slack","body":msg.get("text") or "","created_at":ts}
    def main():
        event = json.load(sys.stdin)
        params = event.get("params") or {}
        op = params.get("messaging_op")
        if event.get("kind") == "manual" and op == "sync_threads":
            emit([{"verb":"http.request","request_id":"sync-1","method":"GET","url":"https://slack.com/api/conversations.list?types=public_channel,private_channel&limit=200&exclude_archived=true","headers":{"Authorization":"Bearer {{secret:bot_token}}"}}])
            return
        if event.get("kind") == "manual" and op == "poll_inbox":
            channel = params.get("vendor_thread_id") or params.get("channel")
            if not channel:
                emit([{"verb":"result.emit","messages":[]}])
                return
            url = "https://slack.com/api/conversations.history?channel=" + str(channel) + "&limit=50"
            emit([{"verb":"http.request","request_id":"poll-1","method":"GET","url":url,"headers":{"Authorization":"Bearer {{secret:bot_token}}"}}])
            return
        if event.get("kind") == "message_in_room" and op == "send_message":
            channel = params.get("vendor_thread_id")
            text = params.get("text", "")
            emit([{"verb":"http.request","request_id":"send-1","method":"POST","url":"https://slack.com/api/chat.postMessage","headers":{"Authorization":"Bearer {{secret:bot_token}}","Content-Type":"application/json"},"body":json.dumps({"channel":channel,"text":text}, separators=(",", ":"))}])
            return
        if event.get("kind") == "http_results" and op == "sync_threads":
            threads = []
            for item in sorted_results(event.get("http_results")):
                if item.get("request_id") != "sync-1": continue
                payload = json.loads(item.get("body") or "{}")
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
                if item.get("request_id") != "poll-1": continue
                payload = json.loads(item.get("body") or "{}")
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
        return {"vendor_thread_id":channel,"vendor_message_id":ts,"direction":"inbound","sender":msg.get("user") or "slack","body":msg.get("text") or "","created_at":ts}
    def main():
        event = json.load(sys.stdin)
        params = event.get("params") or {}
        op = params.get("messaging_op")
        if event.get("kind") == "manual" and op == "sync_threads":
            emit([{"verb":"http.request","request_id":"sync-1","method":"GET","url":"https://slack.com/api/conversations.list?types=public_channel,private_channel&limit=200&exclude_archived=true","headers":{"Authorization":"Bearer {{secret:bot_token}}"}}])
            return
        if event.get("kind") == "manual" and op == "poll_inbox":
            channel = params.get("vendor_thread_id") or params.get("channel")
            if not channel:
                emit([{"verb":"result.emit","messages":[]}])
                return
            url = "https://slack.com/api/conversations.history?channel=" + str(channel) + "&limit=50"
            emit([{"verb":"http.request","request_id":"poll-1","method":"GET","url":url,"headers":{"Authorization":"Bearer {{secret:bot_token}}"}}])
            return
        if event.get("kind") == "message_in_room" and op == "send_message":
            channel = params.get("vendor_thread_id")
            text = params.get("text", "")
            emit([{"verb":"http.request","request_id":"send-1","method":"POST","url":"https://slack.com/api/chat.postMessage","headers":{"Authorization":"Bearer {{secret:bot_token}}","Content-Type":"application/json"},"body":json.dumps({"channel":channel,"text":text}, separators=(",", ":"))}])
            return
        if event.get("kind") == "http_results" and op == "sync_threads":
            threads = []
            for item in sorted_results(event.get("http_results")):
                if item.get("request_id") != "sync-1": continue
                payload = json.loads(item.get("body") or "{}")
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
                if item.get("request_id") != "poll-1": continue
                payload = json.loads(item.get("body") or "{}")
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
