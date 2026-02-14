# Architecture: Custom Events System

## 1. Problem

catpm tracks performance (requests, jobs, queries), but applications also have **business events** that need counting, trending, and inspection — signups, payments, API calls, moderation actions, etc.

Today these are either:
- Not tracked at all
- Scattered across custom tables, Redis counters, and ad-hoc dashboards
- Stored as raw rows (`INSERT` per event) which doesn't scale and requires custom dashboard code

catpm already has aggregated storage (buckets + samples), a flush pipeline, and a dashboard. Adding a simple events API reuses all of this.

## 2. Principles

- **Aggregated-first** — pre-computed counts in time buckets, not raw rows
- **Live samples** — keep a few recent examples per event name for inspection
- **Simple** — no dimensions, no metrics aggregation, no JSON math in v1
- **Zero external deps** — same app DB, same pipeline
- **PG + SQLite** — no adapter-specific features in the schema

## 3. API

```ruby
Catpm.event("spam_detected")
Catpm.event("gpt_call")
Catpm.event("payment_completed")
```

One argument — the event name. Buckets get `+1`. That's it.

Samples (for inspection of recent examples) can carry optional payload:

```ruby
Catpm.event("spam_detected", text: message.text, pattern: "crypto")
```

Payload is stored as JSON on the sample, never queried or aggregated. It's there so you can click a recent event in the dashboard and see what happened.

### Configuration

```ruby
Catpm.configure do |config|
  config.events_enabled = true
  config.events_max_samples_per_name = 20  # rotating window
end
```

Two new config options. Sampling reuses the existing `random_sample_rate` logic.

## 4. Data Model

### `catpm_event_buckets`

```
catpm_event_buckets
├── id              BIGINT PK
├── name            STRING NOT NULL       -- "gpt_call", "spam_detected"
├── bucket_start    DATETIME NOT NULL     -- aligned to minute
├── count           INTEGER DEFAULT 0
│
└── UNIQUE INDEX (name, bucket_start)
```

One row per event name per minute. No dimensions, no JSON columns. Identical behavior on PG and SQLite.

### `catpm_event_samples`

```
catpm_event_samples
├── id              BIGINT PK
├── name            STRING NOT NULL
├── payload         JSON                  -- everything the caller passed
├── recorded_at     DATETIME NOT NULL
│
├── INDEX (name, recorded_at)
└── INDEX (recorded_at)                   -- for cleanup
```

Payload is write-once, read-only — displayed on the detail page, never queried or aggregated.

## 5. Pipeline Integration

### 5.1. CustomEvent

```ruby
module Catpm
  class CustomEvent
    attr_reader :name, :payload, :recorded_at

    def initialize(name:, payload: {})
      @name = name.to_s
      @payload = payload
      @recorded_at = Time.current
    end

    def bucket_start
      @recorded_at.beginning_of_minute
    end

    def estimated_byte_size
      @name.bytesize + (@payload.to_json.bytesize rescue 100) + 50
    end
  end
end
```

Same interface as `Catpm::Event` — `estimated_byte_size` for buffer, `bucket_start` for aggregation.

### 5.2. Entry Point

```ruby
def self.event(name, **payload)
  return unless enabled? && config.events_enabled

  buffer&.push(CustomEvent.new(name: name, payload: payload))
end
```

### 5.3. Flusher

Extend `flush_cycle` to partition drained events:

```ruby
def flush_cycle
  events = buffer.drain
  return if events.empty?

  perf_events, custom_events = events.partition { |e| e.is_a?(Event) }

  # existing performance aggregation...
  aggregate_and_persist(perf_events)

  # new: custom events
  aggregate_custom_events(custom_events) if custom_events.any?
end
```

Aggregation is trivial — group by `[name, bucket_start]`, sum counts:

```ruby
def aggregate_custom_events(events)
  buckets = {}
  samples = []

  events.each do |ce|
    key = [ce.name, ce.bucket_start]
    buckets[key] ||= { name: ce.name, bucket_start: ce.bucket_start, count: 0 }
    buckets[key][:count] += 1

    samples << ce if should_sample_event?(ce)
  end

  adapter.persist_event_buckets(buckets.values)
  adapter.persist_event_samples(samples)
end
```

### 5.4. Adapter

Two new methods on `Adapter::Base`:

```ruby
def persist_event_buckets(buckets)
  # UPSERT: ON CONFLICT (name, bucket_start) DO UPDATE SET count = count + excluded.count
  # Standard SQL, works on both PG and SQLite
end

def persist_event_samples(samples)
  # Batch INSERT
  # Then rotate: DELETE oldest WHERE name = X beyond max_samples_per_name
end
```

No advisory locks needed — single UPSERT per bucket group, simpler than performance buckets.

### 5.5. Downsampling & Cleanup

Same strategy as performance buckets:
- 1-minute → 5-minute after 1 hour (SUM counts, GROUP BY)
- 5-minute → 1-hour after 24 hours
- Delete beyond `retention_period`

Simpler than performance downsampling: just sum the counts, no TDigest merging.

## 6. Queries

All queries use the unique index `(name, bucket_start)`.

```sql
-- Overview: all event names with totals
SELECT name, SUM(count) AS total, MAX(bucket_start) AS last_seen
FROM catpm_event_buckets
WHERE bucket_start >= :since
GROUP BY name
ORDER BY total DESC

-- Time-series for one event
SELECT bucket_start, count
FROM catpm_event_buckets
WHERE name = :name AND bucket_start >= :since
ORDER BY bucket_start

-- Recent samples
SELECT * FROM catpm_event_samples
WHERE name = :name
ORDER BY recorded_at DESC
LIMIT 20
```

No JSON extraction, no dimension filtering, no adapter-specific SQL.

## 7. Dashboard

### `/catpm/events` — Overview

Table:
- **Name** — event name
- **Count** — total for selected time range
- **Trend** — sparkline (reuse existing SVG helper)
- **Last seen** — relative time

Time range filter: 1h / 6h / 24h / 7d (same as performance pages).

### `/catpm/events/:name` — Detail

- **Chart** — count over time (bar chart from bucket data)
- **Recent samples** — list with payload displayed as formatted JSON
- Click sample → expanded payload view

Two pages total. No dimension explorer, no actor views — that's v2.

## 8. Migration Path (tg_filter example)

```ruby
# Before
Event.create!(title: "spam", payload: { text: msg.text }, user_id: user.id, chat_id: chat.id)
Event.where(title: "spam").where(created_at: range).count

# After
Catpm.event("spam", text: msg.text)
# global count: built-in at /catpm/events/spam
# recent examples with payload: visible on the same page
# per-user/per-chat breakdown: v2 (dimensions)
```

## 9. Files

### New:

```
lib/catpm/custom_event.rb                         -- CustomEvent struct
app/models/catpm/event_bucket.rb                   -- AR model (thin)
app/models/catpm/event_sample.rb                   -- AR model (thin)
app/controllers/catpm/events_controller.rb         -- index, show
app/views/catpm/events/index.html.erb              -- overview
app/views/catpm/events/show.html.erb               -- detail + samples
db/migrate/XXXX_create_catpm_event_tables.rb       -- both tables in one migration
```

### Modified:

```
lib/catpm.rb                           -- add Catpm.event()
lib/catpm/configuration.rb             -- events_enabled, events_max_samples_per_name
lib/catpm/flusher.rb                   -- partition + aggregate_custom_events
lib/catpm/adapter/base.rb              -- persist_event_buckets, persist_event_samples
lib/catpm/adapter/postgresql.rb        -- UPSERT implementation
app/views/layouts/catpm/application.html.erb -- Events nav link
config/routes.rb                       -- events routes
```

## 10. Future (v2)

- **Dimensions** — slice events by user/chat/etc. (adds `dim_type` + `dim_id` columns to buckets)
- **Metrics** — numeric values summed in buckets (tokens, cost)
- **Trackable concern** — `user.catpm_events.where(name: "gpt_call")`
- **Actor view** — all events for a specific dimension value
