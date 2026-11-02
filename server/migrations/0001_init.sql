-- Quiz items, shared by everyone who picks the same topic + level.
CREATE TABLE items (
  id TEXT PRIMARY KEY,
  topic TEXT NOT NULL,
  level TEXT NOT NULL,
  payload TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  reports INTEGER NOT NULL DEFAULT 0,
  retired INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX items_bank ON items (topic, level, retired, created_at);

CREATE TABLE topics (
  topic TEXT NOT NULL,
  level TEXT NOT NULL,
  display TEXT NOT NULL,
  last_requested INTEGER NOT NULL,
  needs_refill INTEGER NOT NULL DEFAULT 0,
  generating_until INTEGER NOT NULL DEFAULT 0,
  blocked INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (topic, level)
);

-- Daily Discover feed (key = date) and per-topic field updates (key = topic|date).
CREATE TABLE daily (
  kind TEXT NOT NULL,
  key TEXT NOT NULL,
  payload TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (kind, key)
);

-- Spend tracking; subject is 'global' or 'install:<id>'.
CREATE TABLE usage (
  day TEXT NOT NULL,
  subject TEXT NOT NULL,
  generations INTEGER NOT NULL DEFAULT 0,
  input_tokens INTEGER NOT NULL DEFAULT 0,
  output_tokens INTEGER NOT NULL DEFAULT 0,
  searches INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (day, subject)
);

CREATE TABLE reports (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  item_id TEXT NOT NULL,
  install TEXT NOT NULL,
  reason TEXT NOT NULL,
  note TEXT,
  created_at INTEGER NOT NULL,
  UNIQUE (item_id, install)
);
