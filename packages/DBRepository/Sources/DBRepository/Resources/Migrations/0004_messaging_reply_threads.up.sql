ALTER TABLE messaging_messages ADD COLUMN parent_vendor_message_id TEXT;
ALTER TABLE messaging_messages ADD COLUMN reply_count INTEGER NOT NULL DEFAULT 0;

CREATE INDEX IF NOT EXISTS idx_messaging_messages_parent
    ON messaging_messages(thread_id, parent_vendor_message_id);
