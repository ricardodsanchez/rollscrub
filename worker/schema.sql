-- Aggregate counters, not an event log: one row per day, file and country,
-- incremented in place. Nothing here can be traced to a person, and the table
-- stays small enough to query instantly however long the app sells for.
CREATE TABLE IF NOT EXISTS events (
  day     TEXT    NOT NULL,  -- YYYY-MM-DD, UTC
  kind    TEXT    NOT NULL,  -- 'download' | 'update-check'
  name    TEXT    NOT NULL,  -- 'RollScrub-1.0.zip' | 'appcast'
  country TEXT    NOT NULL,  -- ISO-3166 alpha-2, or '??'
  count   INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (day, kind, name, country)
);

-- People who asked to hear when the shop opens. One row per address, so a
-- second sign-up is not a second email. Deleted on request, and deleted
-- wholesale once the launch mail has gone out — this list has exactly one
-- purpose and no reason to outlive it.
CREATE TABLE IF NOT EXISTS notify (
  email   TEXT PRIMARY KEY,
  day     TEXT NOT NULL,  -- YYYY-MM-DD, UTC
  country TEXT NOT NULL
);
