# frozen_string_literal: true

class CreateCatpmBuckets < ActiveRecord::Migration[8.0]
  def change
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
  end
end
