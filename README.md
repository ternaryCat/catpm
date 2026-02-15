# Catpm

Lightweight, self-hosted performance monitoring for Rails. Track requests, background jobs, errors, and custom traces — all stored in your existing database. No external services, no Redis, no extra infrastructure.

Catpm is designed for small-to-medium Rails applications where a full APM (Datadog, New Relic) is overkill but flying blind is not an option.

## Features

- **HTTP request tracking** — automatic via Rack middleware, zero configuration
- **Background job monitoring** — ActiveJob with queue wait time
- **Custom traces** — instrument any code block with `Catpm.trace` / `Catpm.span`
- **Segment waterfall** — nested breakdown of SQL, views, cache, HTTP, mailers per request
- **Error tracking** — fingerprinting, occurrence counting, context circular buffers
- **Built-in dashboard** — filterable by kind, endpoint drill-down, waterfall visualization
- **Custom events** — track business events (signups, payments, etc.) with `Catpm.event`
- **Auto-instrumentation** — service objects (`ApplicationService`, `BaseService`) traced automatically
- **Multi-database** — PostgreSQL (primary), SQLite (first-class)
- **Zero dependencies** — only Rails >= 7.1, no Redis or background queues required
- **Memory-safe** — configurable buffer limits, automatic downsampling with infinite retention
- **Resilient** — circuit breaker protects your app if the monitoring DB has issues

## Installation

Add to your Gemfile:

```ruby
gem 'catpm'
```

Run the install generator:

```bash
bin/rails generate catpm:install
bin/rails db:migrate
```
Visit `/catpm` in your browser — done.

## Usage

### HTTP requests

Tracked automatically. Every controller action is recorded with duration, status, and segment breakdown (SQL queries, view rendering, cache operations, etc.).

### Background jobs

Enable in the initializer:

```ruby
Catpm.configure do |config|
  config.instrument_jobs = true
end
```

All ActiveJob classes will be tracked with duration and queue wait time.

### Custom traces

Wrap any code block to track it as a standalone operation:

```ruby
Catpm.trace('Stripe::Charge') do
  Stripe::Charge.create(amount: 1000, currency: 'usd')
end
```

Inside an existing request, `Catpm.span` adds a segment to the waterfall instead of creating a separate trace:

```ruby
Catpm.span('geocode', type: :external) do
  Geocoder.search(address)
end
```

For cases where a block doesn't work, use the manual API:

```ruby
span = Catpm.start_trace('long_operation')
# ... do work ...
span.finish
```

### Track non-controller requests

For webhooks, custom Rack endpoints, or anything outside ActionController:

```ruby
Catpm.track_request(kind: :http, target: 'WebhookController#stripe') do
  process_webhook(payload)
end
```

### Declarative method tracing

Include `SpanHelpers` to trace methods without changing their implementation:

```ruby
class PaymentService
  include Catpm::SpanHelpers

  def process(order)
    # ...
  end
  span_method :process

  def self.bulk_charge(users)
    # ...
  end
  span_class_method :bulk_charge
end
```

### Auto-instrumentation

Service objects following the `ApplicationService.call` pattern are instrumented automatically — no configuration needed. If your base class has a different name:

```ruby
Catpm.configure do |config|
  config.service_base_classes = ['MyServiceBase']
end
```

You can also instrument specific methods explicitly:

```ruby
Catpm.configure do |config|
  config.auto_instrument_methods = ['Worker#process', 'Gateway.charge']
end
```

### Custom events

Track business-level events that aren't tied to performance:

```ruby
Catpm.event('user.signed_up', plan: 'pro', source: 'landing_page')
Catpm.event('order.completed', total: 49.99)
```

Events are aggregated into time buckets with sample payloads preserved. Enable in the initializer:

```ruby
Catpm.configure do |config|
  config.events_enabled = true
end
```

## Configuration

The generated initializer (`config/initializers/catpm.rb`) documents all options. Key settings:

```ruby
Catpm.configure do |config|
  # Only run in production/staging
  config.enabled = Rails.env.production? || Rails.env.staging?

  # Protect the dashboard
  config.http_basic_auth_user = ENV['CATPM_USER']
  config.http_basic_auth_password = ENV['CATPM_PASSWORD']
  # Or use a custom policy:
  # config.access_policy = ->(request) { request.env["warden"].user&.admin? }

  # Instrumentation
  config.instrument_jobs = true           # ActiveJob tracking (default: false)
  config.instrument_net_http = true       # Outbound HTTP tracking (default: false)
  config.instrument_middleware_stack = true # Per-middleware segments (default: false)

  # Thresholds
  config.slow_threshold = 500             # ms — global slow threshold
  config.slow_threshold_per_kind = {      # Override per kind
    http: 500,
    job: 5_000,
    custom: 1_000
  }

  # Ignore noisy endpoints
  config.ignored_targets = [
    'HealthcheckController#index',
    '/assets/*',
  ]

  # Tuning
  config.max_buffer_memory = 32.megabytes # In-memory buffer limit
  config.flush_interval = 30              # Seconds between DB flushes
end
```

## How it works

Catpm collects events in a thread-safe in-memory buffer. A background thread flushes the buffer to your database every 30 seconds (configurable). Data is aggregated into time buckets with percentile digests (t-digest), so storage grows slowly regardless of traffic volume.

Data is kept forever with progressively coarser resolution:
- Last hour: 1-minute buckets
- 1 hour – 24 hours: 5-minute buckets
- 1 day – 1 week: 1-hour buckets
- 1 week – 3 months: 1-day buckets
- Older than 3 months: 1-week buckets

This means storage grows logarithmically — years of history take barely more space than a single week of raw data.

A circuit breaker protects your application — if the monitoring DB fails repeatedly, Catpm stops trying and recovers automatically once the DB is healthy again.

## Database support

Catpm stores all data in its own namespaced tables (`catpm_buckets`, `catpm_samples`, `catpm_errors`, `catpm_event_buckets`, `catpm_event_samples`) using your application's existing database connection.

## Requirements

- Ruby >= 3.1
- Rails >= 7.1

## Contributing

1. Fork the repo
2. Create your feature branch (`git checkout -b my-feature`)
3. Run tests: `bin/rails test`
4. Run linter: `bin/rubocop`
5. Commit and push
6. Open a Pull Request

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
