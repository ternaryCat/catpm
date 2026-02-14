# frozen_string_literal: true

class AddCatpmMergeFunction < ActiveRecord::Migration[8.0]
  def up
    return unless postgresql?

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

  def down
    return unless postgresql?

    execute "DROP FUNCTION IF EXISTS catpm_merge_jsonb_sums(jsonb, jsonb);"
  end

  private

  def postgresql?
    ActiveRecord::Base.connection.adapter_name =~ /PostgreSQL/i
  end
end
