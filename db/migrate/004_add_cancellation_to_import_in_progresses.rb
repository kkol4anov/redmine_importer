# frozen_string_literal: true

# A request token provides an atomic lock against double submission. The
# timestamp is a cooperative cancellation flag written by the browser when
# the import page is closed.
class AddCancellationToImportInProgresses < ActiveRecord::Migration[4.2]
  def self.up
    add_column :import_in_progresses, :run_token, :string
    add_column :import_in_progresses, :cancel_requested_at, :datetime
    add_index :import_in_progresses, :run_token
  end

  def self.down
    remove_index :import_in_progresses, :run_token
    remove_column :import_in_progresses, :cancel_requested_at
    remove_column :import_in_progresses, :run_token
  end
end
