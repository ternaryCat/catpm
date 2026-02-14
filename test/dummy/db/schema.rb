# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2025_06_01_000001) do
  create_table "catpm_buckets", force: :cascade do |t|
    t.datetime "bucket_start", null: false
    t.integer "count", default: 0, null: false
    t.float "duration_max", default: 0.0, null: false
    t.float "duration_min", default: 0.0, null: false
    t.float "duration_sum", default: 0.0, null: false
    t.integer "failure_count", default: 0, null: false
    t.string "kind", null: false
    t.json "metadata_sum"
    t.string "operation", default: "", null: false
    t.binary "p95_digest"
    t.integer "success_count", default: 0, null: false
    t.string "target", null: false
    t.index ["bucket_start"], name: "idx_catpm_buckets_time"
    t.index ["kind", "bucket_start"], name: "idx_catpm_buckets_kind_time"
    t.index ["kind", "target", "operation", "bucket_start"], name: "idx_catpm_buckets_unique", unique: true
  end

  create_table "catpm_errors", force: :cascade do |t|
    t.json "contexts"
    t.string "error_class", null: false
    t.string "fingerprint", limit: 64, null: false
    t.datetime "first_occurred_at", null: false
    t.string "kind", null: false
    t.datetime "last_occurred_at", null: false
    t.text "message"
    t.integer "occurrences_count", default: 0, null: false
    t.datetime "resolved_at"
    t.index ["fingerprint"], name: "idx_catpm_errors_fingerprint", unique: true
    t.index ["kind", "last_occurred_at"], name: "idx_catpm_errors_kind_time"
  end

  create_table "catpm_event_buckets", force: :cascade do |t|
    t.datetime "bucket_start", null: false
    t.integer "count", default: 0, null: false
    t.string "name", null: false
    t.index ["bucket_start"], name: "idx_catpm_event_buckets_time"
    t.index ["name", "bucket_start"], name: "idx_catpm_event_buckets_unique", unique: true
  end

  create_table "catpm_event_samples", force: :cascade do |t|
    t.string "name", null: false
    t.json "payload"
    t.datetime "recorded_at", null: false
    t.index ["name", "recorded_at"], name: "idx_catpm_event_samples_name_time"
    t.index ["recorded_at"], name: "idx_catpm_event_samples_time"
  end

  create_table "catpm_samples", force: :cascade do |t|
    t.integer "bucket_id", null: false
    t.json "context"
    t.float "duration", null: false
    t.string "kind", null: false
    t.datetime "recorded_at", null: false
    t.string "sample_type", null: false
    t.index ["bucket_id"], name: "index_catpm_samples_on_bucket_id"
    t.index ["kind", "recorded_at"], name: "idx_catpm_samples_kind_time"
    t.index ["recorded_at"], name: "idx_catpm_samples_time"
  end

  add_foreign_key "catpm_samples", "catpm_buckets", column: "bucket_id"
end
