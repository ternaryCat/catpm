# frozen_string_literal: true

namespace :catpm do
  desc 'Add missing columns to catpm tables (safe to run multiple times)'
  task upgrade: :environment do
    connection = ActiveRecord::Base.connection

    unless connection.column_exists?(:catpm_samples, :error_fingerprint)
      connection.add_column :catpm_samples, :error_fingerprint, :string, limit: 64
      connection.add_index :catpm_samples, :error_fingerprint, name: 'idx_catpm_samples_error_fp'
      puts '[catpm] Added error_fingerprint column to catpm_samples'
    else
      puts '[catpm] catpm_samples.error_fingerprint already exists, skipping'
    end

    unless connection.column_exists?(:catpm_errors, :occurrence_buckets)
      connection.add_column :catpm_errors, :occurrence_buckets, :json
      puts '[catpm] Added occurrence_buckets column to catpm_errors'
    else
      puts '[catpm] catpm_errors.occurrence_buckets already exists, skipping'
    end

    unless connection.table_exists?(:catpm_endpoint_prefs)
      connection.create_table :catpm_endpoint_prefs do |t|
        t.string :kind, null: false
        t.string :target, null: false
        t.string :operation, null: false, default: ''
        t.boolean :pinned, null: false, default: false
        t.boolean :ignored, null: false, default: false
      end
      connection.add_index :catpm_endpoint_prefs, [:kind, :target, :operation],
                           unique: true, name: 'idx_catpm_endpoint_prefs_unique'
      puts '[catpm] Created catpm_endpoint_prefs table'
    else
      puts '[catpm] catpm_endpoint_prefs table already exists, skipping'
    end

    unless connection.table_exists?(:catpm_event_prefs)
      connection.create_table :catpm_event_prefs do |t|
        t.string :name, null: false
        t.boolean :pinned, null: false, default: false
        t.boolean :ignored, null: false, default: false
      end
      connection.add_index :catpm_event_prefs, :name,
                           unique: true, name: 'idx_catpm_event_prefs_unique'
      puts '[catpm] Created catpm_event_prefs table'
    else
      puts '[catpm] catpm_event_prefs table already exists, skipping'
    end
  end
end
