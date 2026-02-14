# frozen_string_literal: true

class CreateCatpmTables < ActiveRecord::Migration[8.0]
  def up
    create_table :catpm_buckets do |t|
      t.string :kind, null: false
      t.string :target, null: false
      t.string :operation, null: false, default: ""
      t.datetime :bucket_start, null: false

      t.integer :count, null: false, default: 0
      t.integer :success_count, null: false, default: 0
      t.integer :failure_count, null: false, default: 0

      t.float :duration_sum, null: false, default: 0.0
      t.float :duration_max, null: false, default: 0.0
      t.float :duration_min, null: false, default: 0.0

      t.json :metadata_sum
      t.binary :p95_digest
    end

    add_index :catpm_buckets, [:kind, :target, :operation, :bucket_start],
              unique: true, name: "idx_catpm_buckets_unique"
    add_index :catpm_buckets, :bucket_start, name: "idx_catpm_buckets_time"
    add_index :catpm_buckets, [:kind, :bucket_start], name: "idx_catpm_buckets_kind_time"

    create_table :catpm_samples do |t|
      t.references :bucket, null: false, foreign_key: { to_table: :catpm_buckets }
      t.string :kind, null: false
      t.string :sample_type, null: false
      t.datetime :recorded_at, null: false
      t.float :duration, null: false
      t.json :context
    end

    add_index :catpm_samples, :recorded_at, name: "idx_catpm_samples_time"
    add_index :catpm_samples, [:kind, :recorded_at], name: "idx_catpm_samples_kind_time"

    create_table :catpm_errors do |t|
      t.string :fingerprint, null: false, limit: 64
      t.string :kind, null: false
      t.string :error_class, null: false
      t.text :message
      t.integer :occurrences_count, null: false, default: 0
      t.datetime :first_occurred_at, null: false
      t.datetime :last_occurred_at, null: false
      t.json :contexts
      t.datetime :resolved_at
    end

    add_index :catpm_errors, :fingerprint, unique: true, name: "idx_catpm_errors_fingerprint"
    add_index :catpm_errors, [:kind, :last_occurred_at], name: "idx_catpm_errors_kind_time"

    create_table :catpm_event_buckets do |t|
      t.string :name, null: false
      t.datetime :bucket_start, null: false
      t.integer :count, null: false, default: 0
    end

    add_index :catpm_event_buckets, [:name, :bucket_start],
              unique: true, name: "idx_catpm_event_buckets_unique"
    add_index :catpm_event_buckets, :bucket_start, name: "idx_catpm_event_buckets_time"

    create_table :catpm_event_samples do |t|
      t.string :name, null: false
      t.json :payload
      t.datetime :recorded_at, null: false
    end

    add_index :catpm_event_samples, [:name, :recorded_at], name: "idx_catpm_event_samples_name_time"
    add_index :catpm_event_samples, :recorded_at, name: "idx_catpm_event_samples_time"

    if postgresql?
      execute <<~SQL
        CREATE OR REPLACE FUNCTION catpm_merge_jsonb_sums(a jsonb, b jsonb)
        RETURNS jsonb AS $$
          SELECT COALESCE(a, '{}'::jsonb) || (
            SELECT jsonb_object_agg(key, COALESCE((a ->> key)::numeric, 0) + value::numeric)
            FROM jsonb_each_text(COALESCE(b, '{}'::jsonb))
          );
        $$ LANGUAGE sql IMMUTABLE;
      SQL
    end
  end

  def down
    if postgresql?
      execute "DROP FUNCTION IF EXISTS catpm_merge_jsonb_sums(jsonb, jsonb);"
    end

    drop_table :catpm_event_samples, if_exists: true
    drop_table :catpm_event_buckets, if_exists: true
    drop_table :catpm_errors, if_exists: true
    drop_table :catpm_samples, if_exists: true
    drop_table :catpm_buckets, if_exists: true
  end

  private

  def postgresql?
    ActiveRecord::Base.connection.adapter_name =~ /PostgreSQL/i
  end
end
