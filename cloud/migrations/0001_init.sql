-- Reel sharing server, initial schema.

CREATE TABLE videos (
  id TEXT PRIMARY KEY,              -- random slug used in links
  title TEXT NOT NULL,
  description TEXT NOT NULL DEFAULT '',
  duration REAL NOT NULL DEFAULT 0,
  size_bytes INTEGER NOT NULL DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'uploading',   -- uploading | ready
  upload_id TEXT,                   -- R2 multipart upload in progress
  privacy TEXT NOT NULL DEFAULT 'unlisted',    -- public | unlisted | password
  password_hash TEXT,               -- PBKDF2, see src/crypto.ts
  chapters TEXT NOT NULL DEFAULT '[]',         -- JSON [{time, title}]
  cta TEXT,                         -- JSON {label, url} or NULL
  links TEXT NOT NULL DEFAULT '[]',            -- JSON [{start, end, label, url}]
  captions TEXT,                    -- WebVTT
  has_thumbnail INTEGER NOT NULL DEFAULT 0,
  has_preview INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE TABLE comments (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  video_id TEXT NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
  author TEXT NOT NULL,
  body TEXT NOT NULL,
  time REAL,                        -- seconds into the video, NULL for a general comment
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
CREATE INDEX comments_video ON comments(video_id, created_at);

CREATE TABLE reactions (
  video_id TEXT NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
  kind TEXT NOT NULL,               -- thumbs | heart | laugh | wow | clap
  time REAL,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
CREATE INDEX reactions_video ON reactions(video_id);

-- One row per viewer session; percent is updated as they watch.
CREATE TABLE views (
  id TEXT PRIMARY KEY,
  video_id TEXT NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
  viewer TEXT,                      -- name the viewer gave, if any
  percent REAL NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
CREATE INDEX views_video ON views(video_id, created_at);

-- R2 operations counted per month, to stop before the free tier ends.
CREATE TABLE usage (
  month TEXT PRIMARY KEY,           -- YYYY-MM
  write_ops INTEGER NOT NULL DEFAULT 0,
  read_ops INTEGER NOT NULL DEFAULT 0
);

-- Workspace settings: branding and defaults. Single row, key = 'workspace'.
CREATE TABLE settings (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
