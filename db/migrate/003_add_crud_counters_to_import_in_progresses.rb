# frozen_string_literal: true

# The combined mode leaves the issues no row changes untouched, and the
# deletion mode destroys them instead of writing to them. Both outcomes are
# counted next to the created and the updated ones, so the progress the page
# polls has to carry them as well.
class AddCrudCountersToImportInProgresses < ActiveRecord::Migration[4.2]
  def self.up
    add_column :import_in_progresses, :unchanged_count, :integer, default: 0
    add_column :import_in_progresses, :deleted_count, :integer, default: 0
  end

  def self.down
    remove_column :import_in_progresses, :unchanged_count
    remove_column :import_in_progresses, :deleted_count
  end
end
