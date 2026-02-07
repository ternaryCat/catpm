# frozen_string_literal: true

class CreateCatpmSamples < ActiveRecord::Migration[8.0]
  def change
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
  end
end
