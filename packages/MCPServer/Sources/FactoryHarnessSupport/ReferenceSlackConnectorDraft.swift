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
        "extensions":{"app.derrick":{"entrypoint":"./app.derrick/plugin.go","role":"connector","auth_scheme":"bot_token","secrets":[{"id":"bot_token","label":"Bot Token","kind":"token"}],"permissions":["channels:history","channels:read","chat:write","groups:history","groups:read","im:history","im:read","mpim:history","mpim:read","users:read"],"messaging_ops":[\(opsJSON)]}}}
        """
        return PluginFactoryDraft(
            manifestJSON: manifestJSON,
            guestSource: source,
            testInput: Data(testInput.utf8),
            userGoal: userGoal
        )
    }

    private static let fullSyncSource = """
    package main

    import (
        "encoding/json"
        "os"
        "sort"
    )

    func emit(v any) {
        enc := json.NewEncoder(os.Stdout)
        enc.SetEscapeHTML(false)
        _ = enc.Encode(v)
    }

    func sortedResults(results []map[string]any) []map[string]any {
        if len(results) == 0 {
            return nil
        }
        sort.Slice(results, func(i, j int) bool {
            left, _ := results[i]["request_id"].(string)
            right, _ := results[j]["request_id"].(string)
            return left < right
        })
        seen := map[string]bool{}
        out := []map[string]any{}
        for _, item := range results {
            rid, _ := item["request_id"].(string)
            if rid == "" || seen[rid] {
                continue
            }
            seen[rid] = true
            out = append(out, item)
        }
        return out
    }

    func asMap(v any) map[string]any {
        if m, ok := v.(map[string]any); ok {
            return m
        }
        return map[string]any{}
    }

    func asString(v any) string {
        if s, ok := v.(string); ok {
            return s
        }
        return ""
    }

    func messageFrom(msg map[string]any, defaultChannel string) map[string]any {
        channel := asString(msg["channel"])
        if channel == "" {
            channel = defaultChannel
        }
        ts := asString(msg["ts"])
        if channel == "" || ts == "" {
            return nil
        }
        threadTS := asString(msg["thread_ts"])
        parent := ""
        if threadTS != "" && threadTS != ts {
            parent = threadTS
        }
        replyCount := 0
        if n, ok := msg["reply_count"].(float64); ok {
            replyCount = int(n)
        }
        row := map[string]any{
            "vendor_thread_id": channel,
            "vendor_message_id": ts,
            "direction": "inbound",
            "sender": func() string {
                if s := asString(msg["user"]); s != "" {
                    return s
                }
                return "slack"
            }(),
            "body": asString(msg["text"]),
            "created_at": ts,
            "reply_count": replyCount,
        }
        if parent != "" {
            row["parent_vendor_message_id"] = parent
        }
        return row
    }

    func main() {
        var event map[string]any
        if err := json.NewDecoder(os.Stdin).Decode(&event); err != nil {
            return
        }
        params := asMap(event["params"])
        op := asString(params["messaging_op"])
        kind := asString(event["kind"])

        switch {
        case kind == "manual" && op == "sync_threads":
            emit([]map[string]any{{
                "verb": "http.request", "request_id": "sync-1", "method": "GET",
                "url": "https://slack.com/api/conversations.list?types=public_channel,private_channel&limit=200&exclude_archived=true",
                "headers": map[string]any{"Authorization": "Bearer {{secret:bot_token}}"},
            }})
            return
        case kind == "manual" && op == "poll_inbox":
            channel := asString(params["vendor_thread_id"])
            if channel == "" {
                channel = asString(params["channel"])
            }
            parent := asString(params["parent_vendor_message_id"])
            if parent == "" {
                parent = asString(params["thread_ts"])
            }
            if channel == "" {
                emit([]map[string]any{{"verb": "result.emit", "messages": []map[string]any{}}})
                return
            }
            if parent != "" {
                url := "https://slack.com/api/conversations.replies?channel=" + channel + "&ts=" + parent + "&limit=50"
                emit([]map[string]any{{
                    "verb": "http.request", "request_id": "replies-1", "method": "GET", "url": url,
                    "headers": map[string]any{"Authorization": "Bearer {{secret:bot_token}}"},
                }})
                return
            }
            url := "https://slack.com/api/conversations.history?channel=" + channel + "&limit=50"
            emit([]map[string]any{{
                "verb": "http.request", "request_id": "poll-1", "method": "GET", "url": url,
                "headers": map[string]any{"Authorization": "Bearer {{secret:bot_token}}"},
            }})
            return
        case kind == "message_in_room" && op == "send_message":
            channel := asString(params["vendor_thread_id"])
            text := asString(params["text"])
            parent := asString(params["parent_vendor_message_id"])
            if parent == "" {
                parent = asString(params["thread_ts"])
            }
            payload := map[string]any{"channel": channel, "text": text}
            if parent != "" {
                payload["thread_ts"] = parent
            }
            emit([]map[string]any{{
                "verb": "http.request", "request_id": "send-1", "method": "POST",
                "url": "https://slack.com/api/chat.postMessage",
                "headers": map[string]any{
                    "Authorization": "Bearer {{secret:bot_token}}",
                    "Content-Type": "application/json",
                },
                "json": payload,
            }})
            return
        case kind == "http_results" && op == "sync_threads":
            threads := []map[string]any{}
            rawResults, _ := event["http_results"].([]any)
            results := []map[string]any{}
            for _, item := range rawResults {
                results = append(results, asMap(item))
            }
            for _, item := range sortedResults(results) {
                if asString(item["request_id"]) != "sync-1" {
                    continue
                }
                var payload map[string]any
                _ = json.Unmarshal([]byte(asString(item["body"])), &payload)
                if payload["ok"] == false {
                    emit([]map[string]any{{
                        "verb": "result.emit",
                        "title": "Slack list failed",
                        "summary": asString(payload["error"]),
                    }})
                    return
                }
                channels, _ := payload["channels"].([]any)
                sort.Slice(channels, func(i, j int) bool {
                    left := asMap(channels[i])
                    right := asMap(channels[j])
                    return asString(left["id"]) < asString(right["id"])
                })
                for _, chAny := range channels {
                    ch := asMap(chAny)
                    if ch["is_member"] == false {
                        continue
                    }
                    cid := asString(ch["id"])
                    name := asString(ch["name"])
                    if name == "" {
                        name = cid
                    }
                    if cid != "" {
                        threads = append(threads, map[string]any{
                            "vendor_thread_id": cid,
                            "title": "#" + name,
                        })
                    }
                }
            }
            emit([]map[string]any{{"verb": "result.emit", "threads": threads}})
            return
        case kind == "http_results" && op == "poll_inbox":
            channel := asString(params["vendor_thread_id"])
            if channel == "" {
                channel = asString(params["channel"])
            }
            messages := []map[string]any{}
            rawResults, _ := event["http_results"].([]any)
            results := []map[string]any{}
            for _, item := range rawResults {
                results = append(results, asMap(item))
            }
            for _, item := range sortedResults(results) {
                rid := asString(item["request_id"])
                if rid != "poll-1" && rid != "replies-1" {
                    continue
                }
                var payload map[string]any
                _ = json.Unmarshal([]byte(asString(item["body"])), &payload)
                if payload["ok"] == false {
                    emit([]map[string]any{{
                        "verb": "result.emit",
                        "title": "Slack blocked this thread",
                        "summary": asString(payload["error"]),
                    }})
                    return
                }
                rawMessages, _ := payload["messages"].([]any)
                sort.Slice(rawMessages, func(i, j int) bool {
                    left := asMap(rawMessages[i])
                    right := asMap(rawMessages[j])
                    return asString(left["ts"]) < asString(right["ts"])
                })
                for _, msgAny := range rawMessages {
                    parsed := messageFrom(asMap(msgAny), channel)
                    if parsed != nil {
                        messages = append(messages, parsed)
                    }
                }
            }
            emit([]map[string]any{{"verb": "result.emit", "messages": messages}})
            return
        case kind == "http_results" && op == "send_message":
            body := map[string]any{}
            rawResults, _ := event["http_results"].([]any)
            results := []map[string]any{}
            for _, item := range rawResults {
                results = append(results, asMap(item))
            }
            for _, item := range sortedResults(results) {
                if asString(item["request_id"]) == "send-1" {
                    _ = json.Unmarshal([]byte(asString(item["body"])), &body)
                }
            }
            if body["ok"] == true {
                ts := asString(body["ts"])
                if ts == "" {
                    ts = asString(asMap(body["message"])["ts"])
                }
                emit([]map[string]any{{
                    "verb": "result.emit",
                    "sent_message": map[string]any{
                        "vendor_message_id": ts,
                        "created_at": ts,
                    },
                }})
            } else {
                emit([]map[string]any{{"verb": "result.emit", "summary": "send failed"}})
            }
            return
        default:
            emit([]map[string]any{{"verb": "result.emit", "summary": "unsupported"}})
        }
    }
    """
}
