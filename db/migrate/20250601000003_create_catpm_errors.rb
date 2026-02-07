# frozen_string_literal: true

class CreateCatpmErrors < ActiveRecord::Migration[8.0]
  def change
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
  end
end
