# frozen_string_literal: true

namespace :catpm do
  desc "Seed realistic custom event data (7 days, 9 event types)"
  task seed_events: :environment do
    EVENT_TYPES = {
      "allowed"    => { weight: 35, payload: -> { { user_id: rand(1..5000), chat_id: rand(1..2000) } } },
      "gpt"        => { weight: 15, payload: -> { { model: %w[gpt-4o gpt-4o-mini].sample, tokens: rand(50..2000), user_id: rand(1..5000) } } },
      "cache"      => { weight: 15, payload: -> { { hit: [true, false].sample, key: "msg:#{rand(1..10000)}" } } },
      "spam"       => { weight: 10, payload: -> { { user_id: rand(1..5000), score: rand(0.7..1.0).round(2), action: "blocked" } } },
      "moderation" => { weight: 10, payload: -> { { user_id: rand(1..5000), category: %w[hate violence self-harm].sample, flagged: [true, false].sample } } },
      "ratelimit"  => { weight: 5,  payload: -> { { user_id: rand(1..5000), limit: %w[messages commands media].sample } } },
      "command"    => { weight: 4,  payload: -> { { command: %w[/start /help /settings /stats /premium].sample, user_id: rand(1..5000) } } },
      "payment"    => { weight: 3,  payload: -> { { amount: [299, 499, 999].sample, currency: "USD", user_id: rand(1..5000) } } },
      "error"      => { weight: 3,  payload: -> { { error_class: %w[Timeout::Error Net::ReadTimeout Redis::CannotConnectError].sample, context: "background" } } }
    }.freeze

    # Build weighted pool
    pool = EVENT_TYPES.flat_map { |name, cfg| [name] * cfg[:weight] }

    days = 7
    start_time = days.days.ago.beginning_of_hour
    end_time = Time.current

    puts "Seeding event buckets from #{start_time} to #{end_time}..."

    # Generate 1-minute buckets
    bucket_records = []
    current = start_time

    while current < end_time
      hour = current.hour
      # Lower activity at night (2am-7am)
      base_rate = (hour >= 2 && hour < 7) ? rand(30..80) : rand(200..500)

      # Distribute events across types for this minute
      counts = Hash.new(0)
      base_rate.times { counts[pool.sample] += 1 }

      counts.each do |name, count|
        bucket_records << {
          name: name,
          bucket_start: current,
          count: count
        }
      end

      current += 1.minute

      # Batch insert every hour of data
      if bucket_records.size >= 500
        Catpm::EventBucket.insert_all(bucket_records)
        bucket_records.clear
        print "."
      end
    end

    Catpm::EventBucket.insert_all(bucket_records) if bucket_records.any?
    puts "\nInserted #{Catpm::EventBucket.count} event buckets."

    # Generate samples (20 per event type)
    puts "Seeding event samples..."
    sample_records = []
    EVENT_TYPES.each do |name, cfg|
      20.times do
        recorded_at = start_time + rand((end_time - start_time).to_i).seconds
        sample_records << {
          name: name,
          payload: cfg[:payload].call.to_json,
          recorded_at: recorded_at
        }
      end
    end

    Catpm::EventSample.insert_all(sample_records) if sample_records.any?
    puts "Inserted #{Catpm::EventSample.count} event samples."
    puts "Done!"
  end
end
