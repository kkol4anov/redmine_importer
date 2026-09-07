# frozen_string_literal: true

# The row of the import in progress keeps the state of the request performing
# it, so that the page that started the import can poll it and show how far it
# has got. The row is no longer deleted when the import is over: it is marked
# finished and loses its payload, so that the final state stays readable.
class AddProgressToImportInProgresses < ActiveRecord::Migration[4.2]
  def self.up
    add_column :import_in_progresses, :stage, :string, limit: 32
    add_column :import_in_progresses, :total_rows, :integer, default: 0
    add_column :import_in_progresses, :processed_rows, :integer, default: 0
    add_column :import_in_progresses, :created_count, :integer, default: 0
    add_column :import_in_progresses, :updated_count, :integer, default: 0
    add_column :import_in_progresses, :skipped_count, :integer, default: 0
    add_column :import_in_progresses, :failed_count, :integer, default: 0
    add_column :import_in_progresses, :refreshed_at, :datetime
    add_column :import_in_progresses, :finished_at, :datetime
  end

  def self.down
    remove_column :import_in_progresses, :stage
    remove_column :import_in_progresses, :total_rows
    remove_column :import_in_progresses, :processed_rows
    remove_column :import_in_progresses, :created_count
    remove_column :import_in_progresses, :updated_count
    remove_column :import_in_progresses, :skipped_count
    remove_column :import_in_progresses, :failed_count
    remove_column :import_in_progresses, :refreshed_at
    remove_column :import_in_progresses, :finished_at
  end
end
