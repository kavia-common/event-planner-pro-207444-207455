#!/bin/bash
set -euo pipefail

# Idempotent schema + seed initializer for the Event Planner app.
# Intended to be invoked by startup.sh after the DB is up.
#
# NOTE:
# - We intentionally use the connection string from db_connection.txt (container convention).
# - We keep statements mostly "one at a time" inside psql using a single -v ON_ERROR_STOP=1 batch.
#   This is still safe and repeatable because we use IF NOT EXISTS / ON CONFLICT guards.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONN_CMD_FILE="${SCRIPT_DIR}/db_connection.txt"

if [ ! -f "${CONN_CMD_FILE}" ]; then
  echo "ERROR: db_connection.txt not found at ${CONN_CMD_FILE}"
  echo "Run startup.sh first to bootstrap Postgres and generate db_connection.txt."
  exit 1
fi

CONN_CMD="$(cat "${CONN_CMD_FILE}")"
# db_connection.txt contains something like: psql postgresql://user:pass@host:port/db
PSQL="${CONN_CMD}"

echo "Applying schema to event planner database..."

# IMPORTANT:
# - In bash, $$ expands to PID. When writing SQL functions using $$, ensure you escape as needed.
# - Here we run a heredoc directly into psql; $$ will be preserved literally.
${PSQL} -v ON_ERROR_STOP=1 <<'SQL'
BEGIN;

-- Extensions (for UUID defaults)
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- =========
-- Core user profile table
-- =========
CREATE TABLE IF NOT EXISTS profiles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  -- Supabase-friendly: this can map to auth.users.id
  user_id uuid UNIQUE NOT NULL,

  email text UNIQUE,
  display_name text NOT NULL CHECK (char_length(display_name) BETWEEN 1 AND 80),
  avatar_url text,
  bio text,

  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- =========
-- Optional normalized locations
-- =========
CREATE TABLE IF NOT EXISTS locations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL CHECK (char_length(name) BETWEEN 1 AND 120),
  address1 text,
  address2 text,
  city text,
  region text,
  postal_code text,
  country text,
  latitude double precision,
  longitude double precision,
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT locations_lat_lng_chk
    CHECK (
      (latitude IS NULL AND longitude IS NULL)
      OR
      (latitude BETWEEN -90 AND 90 AND longitude BETWEEN -180 AND 180)
    )
);

-- =========
-- Events
-- =========
CREATE TABLE IF NOT EXISTS events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

  owner_id uuid NOT NULL,
  title text NOT NULL CHECK (char_length(title) BETWEEN 1 AND 140),
  description text,

  start_at timestamptz NOT NULL,
  end_at timestamptz NOT NULL,
  timezone text NOT NULL DEFAULT 'UTC',
  is_all_day boolean NOT NULL DEFAULT false,

  capacity integer,
  location_id uuid,
  location_text text,

  visibility text NOT NULL DEFAULT 'private' CHECK (visibility IN ('private','public','unlisted')),
  status text NOT NULL DEFAULT 'scheduled' CHECK (status IN ('scheduled','cancelled')),

  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT events_time_chk CHECK (end_at > start_at),
  CONSTRAINT events_capacity_chk CHECK (capacity IS NULL OR capacity >= 0),
  -- If location_id is set, we expect location_text to be empty/NULL (avoid conflicting sources).
  CONSTRAINT events_location_oneof_chk CHECK (
    (location_id IS NULL)
    OR
    (location_text IS NULL OR btrim(location_text) = '')
  )
);

-- =========
-- Tags + join table
-- =========
CREATE TABLE IF NOT EXISTS tags (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL UNIQUE CHECK (char_length(name) BETWEEN 1 AND 40),
  color text,
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS event_tags (
  event_id uuid NOT NULL,
  tag_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (event_id, tag_id)
);

-- =========
-- RSVPs
-- =========
CREATE TABLE IF NOT EXISTS rsvps (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id uuid NOT NULL,
  user_id uuid NOT NULL,

  status text NOT NULL DEFAULT 'yes' CHECK (status IN ('yes','no','maybe','waitlist')),
  guests_count integer NOT NULL DEFAULT 0 CHECK (guests_count >= 0 AND guests_count <= 20),
  comment text,

  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),

  UNIQUE (event_id, user_id)
);

-- =========
-- Foreign keys (conditional add via DO blocks)
-- =========

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'locations_created_by_fk'
  ) THEN
    ALTER TABLE locations
      ADD CONSTRAINT locations_created_by_fk
      FOREIGN KEY (created_by) REFERENCES profiles(user_id) ON DELETE SET NULL;
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'events_owner_fk'
  ) THEN
    ALTER TABLE events
      ADD CONSTRAINT events_owner_fk
      FOREIGN KEY (owner_id) REFERENCES profiles(user_id) ON DELETE CASCADE;
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'events_location_fk'
  ) THEN
    ALTER TABLE events
      ADD CONSTRAINT events_location_fk
      FOREIGN KEY (location_id) REFERENCES locations(id) ON DELETE SET NULL;
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'tags_created_by_fk'
  ) THEN
    ALTER TABLE tags
      ADD CONSTRAINT tags_created_by_fk
      FOREIGN KEY (created_by) REFERENCES profiles(user_id) ON DELETE SET NULL;
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'event_tags_event_fk'
  ) THEN
    ALTER TABLE event_tags
      ADD CONSTRAINT event_tags_event_fk
      FOREIGN KEY (event_id) REFERENCES events(id) ON DELETE CASCADE;
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'event_tags_tag_fk'
  ) THEN
    ALTER TABLE event_tags
      ADD CONSTRAINT event_tags_tag_fk
      FOREIGN KEY (tag_id) REFERENCES tags(id) ON DELETE CASCADE;
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'rsvps_event_fk'
  ) THEN
    ALTER TABLE rsvps
      ADD CONSTRAINT rsvps_event_fk
      FOREIGN KEY (event_id) REFERENCES events(id) ON DELETE CASCADE;
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'rsvps_user_fk'
  ) THEN
    ALTER TABLE rsvps
      ADD CONSTRAINT rsvps_user_fk
      FOREIGN KEY (user_id) REFERENCES profiles(user_id) ON DELETE CASCADE;
  END IF;
END $$;

-- =========
-- Indexes
-- =========
CREATE INDEX IF NOT EXISTS idx_profiles_user_id ON profiles(user_id);

CREATE INDEX IF NOT EXISTS idx_events_owner_start ON events(owner_id, start_at);
CREATE INDEX IF NOT EXISTS idx_events_start_at ON events(start_at);

CREATE INDEX IF NOT EXISTS idx_rsvps_event_status ON rsvps(event_id, status);

CREATE INDEX IF NOT EXISTS idx_event_tags_tag_id ON event_tags(tag_id);

-- =========
-- updated_at automation
-- =========
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS trigger AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS set_profiles_updated_at ON profiles;
CREATE TRIGGER set_profiles_updated_at
BEFORE UPDATE ON profiles
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS set_locations_updated_at ON locations;
CREATE TRIGGER set_locations_updated_at
BEFORE UPDATE ON locations
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS set_events_updated_at ON events;
CREATE TRIGGER set_events_updated_at
BEFORE UPDATE ON events
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS set_tags_updated_at ON tags;
CREATE TRIGGER set_tags_updated_at
BEFORE UPDATE ON tags
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS set_rsvps_updated_at ON rsvps;
CREATE TRIGGER set_rsvps_updated_at
BEFORE UPDATE ON rsvps
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMIT;

-- =========
-- Development seed data (idempotent)
-- =========

INSERT INTO profiles (user_id, email, display_name, bio)
VALUES ('00000000-0000-0000-0000-000000000001','alex@example.com','Alex Retro','Organizer and synthwave enthusiast')
ON CONFLICT (user_id) DO NOTHING;

INSERT INTO profiles (user_id, email, display_name, bio)
VALUES ('00000000-0000-0000-0000-000000000002','blake@example.com','Blake Neon','Always RSVPs maybe')
ON CONFLICT (user_id) DO NOTHING;

INSERT INTO profiles (user_id, email, display_name, bio)
VALUES ('00000000-0000-0000-0000-000000000003','casey@example.com','Casey Pixel','Likes calendars and coffee')
ON CONFLICT (user_id) DO NOTHING;

INSERT INTO locations (id, name, address1, city, region, country, latitude, longitude, created_by)
VALUES ('10000000-0000-0000-0000-000000000001','Neon Arcade','123 Synth St','Miami','FL','US',25.7617,-80.1918,'00000000-0000-0000-0000-000000000001')
ON CONFLICT (id) DO NOTHING;

INSERT INTO tags (id, name, color, created_by)
VALUES ('20000000-0000-0000-0000-000000000001','retro','#FF00FF','00000000-0000-0000-0000-000000000001')
ON CONFLICT (id) DO NOTHING;

INSERT INTO tags (id, name, color, created_by)
VALUES ('20000000-0000-0000-0000-000000000002','meetup','#00E5FF','00000000-0000-0000-0000-000000000001')
ON CONFLICT (id) DO NOTHING;

INSERT INTO events (id, owner_id, title, description, start_at, end_at, timezone, is_all_day, capacity, location_id, visibility, status)
VALUES (
  '30000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000001',
  'Synthwave Planning Session',
  'Brainstorm the next big neon event',
  now() + interval '2 days',
  now() + interval '2 days 2 hours',
  'UTC',
  false,
  25,
  '10000000-0000-0000-0000-000000000001',
  'private',
  'scheduled'
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO events (id, owner_id, title, description, start_at, end_at, timezone, is_all_day, capacity, location_text, visibility, status)
VALUES (
  '30000000-0000-0000-0000-000000000002',
  '00000000-0000-0000-0000-000000000001',
  'Public Retro Picnic',
  'Bring your best 90s snacks',
  now() + interval '7 days',
  now() + interval '7 days 4 hours',
  'UTC',
  false,
  100,
  'Sunset Park',
  'public',
  'scheduled'
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO event_tags (event_id, tag_id)
VALUES ('30000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001')
ON CONFLICT DO NOTHING;

INSERT INTO event_tags (event_id, tag_id)
VALUES ('30000000-0000-0000-0000-000000000002','20000000-0000-0000-0000-000000000002')
ON CONFLICT DO NOTHING;

INSERT INTO rsvps (id, event_id, user_id, status, guests_count, comment)
VALUES (
  '40000000-0000-0000-0000-000000000001',
  '30000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000002',
  'maybe',
  1,
  'Depends on the vibe'
)
ON CONFLICT (event_id, user_id) DO NOTHING;

SQL

echo "Schema + seed applied successfully."
