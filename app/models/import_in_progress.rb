require 'nkf'
class ImportInProgress < ActiveRecord::Base
  # The import is being set up: the options are validated and the rows of the
  # file are counted
  STAGE_PREPARING = 'preparing'
  # Existing issues are fetched in SQL batches before rows are processed
  STAGE_LOOKUP = 'lookup'
  # The rows are being imported, processed_rows out of total_rows are done
  STAGE_IMPORTING = 'importing'
  # The rows are being turned into the issues they name, before anything is
  # destroyed, processed_rows out of total_rows are done
  STAGE_MATCHING = 'matching'
  # The issues are being deleted, processed_rows out of total_rows are done.
  # Here a row of the progress is an issue, not a row of the file.
  STAGE_DELETING = 'deleting'
  # The rows are over, the references that could not be resolved right away
  # are being finished off
  STAGE_FINALIZING = 'finalizing'
  # The import is over and its result is ready
  STAGE_FINISHED = 'finished'
  # The import was stopped by an error and its result page carries it
  STAGE_FAILED = 'failed'
  # The browser left the import page and asked the worker to stop
  STAGE_CANCELLED = 'cancelled'
  # There is no import of this user to report on
  STAGE_UNKNOWN = 'unknown'

  FINAL_STAGES = [STAGE_FINISHED, STAGE_FAILED, STAGE_CANCELLED].freeze

  belongs_to :user
  belongs_to :project

  before_save :encode_csv_data

  # The import the browser is waiting for, or nil when the user runs no import
  # or has already started another one: a page left open from a previous run
  # must not report on the current import.
  def self.current_for(user, import_timestamp = nil)
    iip = where(user_id: user.id).order(:id).last
    return nil if iip.nil?
    return nil if import_timestamp.present? && iip.timestamp != import_timestamp.to_s

    iip
  end

  # The identifier the pages of the import carry around, telling one import of
  # the user from the next one
  def timestamp
    created&.strftime('%Y-%m-%d %H:%M:%S')
  end

  # Writes the state of the running import. It goes through +update_columns+,
  # so that it is committed right away and can be read by the requests polling
  # it, and so that no callback or validation slows down the loop.
  def report!(attributes)
    update_columns(attributes.merge(refreshed_at: Time.now))
  end

  # Claims the row for exactly one result request. The conditional UPDATE is
  # deliberately atomic: checking +running?+ and updating afterwards lets two
  # near-simultaneous submissions import the same CSV twice.
  def claim!(token)
    return false if token.blank?

    claimed = self.class.where(id: id, run_token: [nil, ''], finished_at: nil)
                        .update_all(run_token: token, cancel_requested_at: nil,
                                    stage: STAGE_PREPARING,
                                    refreshed_at: Time.now)
    reload if claimed == 1
    claimed == 1
  end

  def request_cancel!(token)
    return false if token.blank?

    changed = self.class.where(id: id, run_token: token, finished_at: nil)
                        .update_all(cancel_requested_at: Time.now,
                                    refreshed_at: Time.now)
    changed == 1
  end

  # Reload only the one column used as a cooperative cancellation flag. This
  # is called at the same throttled cadence as progress reporting, not for
  # every imported field.
  def cancel_requested?
    self.class.where(id: id).pluck(:cancel_requested_at).first.present?
  end

  def finished?
    FINAL_STAGES.include?(stage)
  end

  def percent_complete
    return 100 if finished?
    return 0 if total_rows.to_i <= 0

    [[processed_rows.to_i * 100 / total_rows.to_i, 100].min, 0].max
  end

  # The payload polled by the progress panel
  def as_status
    {
      stage: stage.presence || STAGE_PREPARING,
      finished: finished?,
      percent: percent_complete,
      total_rows: total_rows.to_i,
      processed_rows: processed_rows.to_i,
      created_count: created_count.to_i,
      updated_count: updated_count.to_i,
      unchanged_count: unchanged_count.to_i,
      deleted_count: deleted_count.to_i,
      skipped_count: skipped_count.to_i,
      failed_count: failed_count.to_i
    }
  end

  private
  def encode_csv_data
    return if self.csv_data.blank?

    self.csv_data = self.csv_data
    # 入力文字コード
    encode = case self.encoding
             when "U"
               "-W"
             when "EUC"
               "-E"
             when "S"
               "-S"
             when "N"
               ""
             else
               ""
             end

    self.csv_data = NKF.nkf("#{encode} -w", self.csv_data).encode('UTF-8', 'UTF-8', invalid: :replace, undef: :replace)
  end
end
