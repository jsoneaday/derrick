CREATE TABLE IF NOT EXISTS news_readers (
    id TEXT PRIMARY KEY NOT NULL,
    name TEXT NOT NULL,
    topics_json TEXT NOT NULL DEFAULT '[]',
    sources_json TEXT NOT NULL DEFAULT '[]',
    mode TEXT NOT NULL,
    max_count INTEGER NOT NULL,
    schedule TEXT NOT NULL,
    summary_text TEXT,
    last_error TEXT,
    last_fetched_at TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS news_items (
    id TEXT PRIMARY KEY NOT NULL,
    reader_id TEXT NOT NULL,
    title TEXT NOT NULL,
    source_url TEXT NOT NULL,
    source_label TEXT NOT NULL,
    summary TEXT,
    published_at TEXT,
    fetched_at TEXT NOT NULL,
    UNIQUE(reader_id, source_url),
    FOREIGN KEY(reader_id) REFERENCES news_readers(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_news_items_reader
    ON news_items(reader_id, fetched_at DESC);
