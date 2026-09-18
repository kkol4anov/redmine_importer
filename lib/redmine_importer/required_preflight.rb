# frozen_string_literal: true

module RedmineImporter
  module RequiredPreflight
    private

    # Read-only: no issue assignment, journals, callbacks, categories or
    # versions are written here. Even the lookup cache objects stay untouched.
    def required_csv_fields_missing?(rows, unique_attr, unique_field, updating)
      begin_progress_phase(ImportInProgress::STAGE_VALIDATING, rows.size)
      @required_validation_failed = false
      @file_validation_results = []
      schemas = {}
      default_tracker = @project.trackers.find_by(id: params[:default_tracker])
      default_statuses = {}
      rows.each_with_index do |row, index|
        @processed_rows = index + 1
        report_progress
        existing = nil
        if updating && matchable_row?(row, unique_field)
          begin
            existing = issue_for_unique_attr(unique_attr, row[unique_field], row)
          rescue NoIssueForUniqueValue
            next if params[:ignore_non_exist].present?
          rescue MultipleIssuesForUniqueValue, UnusableUniqueField, ActiveRecord::RecordNotFound => e
            record_required_preflight_error(row, index, unique_field, e.message)
            next
          end
        end
        next if existing && existing.project_id != @project.id && params[:update_other_project].blank?

        project = existing ? existing.project : @project
        tracker = tracker_by_name(fetch('standard_field-tracker', row))
        tracker ||= existing&.tracker || default_tracker
        status = status_by_name(fetch('standard_field-status', row))
        next if existing&.status&.is_closed? && (status.nil? || status.is_closed?)
        defaults = project.id == @project.id && tracker&.id.to_s == params[:default_tracker].to_s ? required_defaults_params : {}
        default_status_id = defaults['status_id'].presence
        default_status = if default_status_id
                           default_statuses[default_status_id] ||= IssueStatus.find_by(id: default_status_id)
                         end
        status ||= existing&.status || default_status || tracker&.default_status
        unless tracker && status
          record_required_preflight_error(row, index, unique_field,
            l(:error_import_required_fields, fields: [l(:field_tracker), l(:field_status)].join(', ')))
          next
        end

        schema_key = [project.id, tracker.id, status.id]
        schema = schemas[schema_key] ||= begin
          sample = Issue.new(project: project, tracker: tracker, status: status, author: User.current)
          core, custom = RequiredDefaults.required(sample)
          { issue: sample, core: core,
            custom: sample.available_custom_fields.select { |cf| custom.include?(cf.id.to_s) },
            editable: sample.editable_custom_fields.map { |cf| cf.id.to_s } }
        end
        sample = schema[:issue]
        missing = schema[:core].filter_map do |attribute|
          key = RequiredDefaults.csv_key(attribute)
          fallback = sample.safe_attribute?(attribute) ? defaults[attribute] : nil
          stored = (existing || sample).public_send(attribute)
          next if required_preflight_value?(row, key, fallback, stored)

          l_or_humanize(attribute.delete_suffix('_id'), prefix: 'field_')
        end
        cf_defaults = defaults['custom_field_values'] || {}
        schema[:custom].each do |field|
          fallback = schema[:editable].include?(field.id.to_s) && cf_defaults.respond_to?(:keys) ? cf_defaults[field.id.to_s] : nil
          stored = (existing || sample).custom_field_value(field.id)
          next if required_preflight_value?(row, "custom_field-#{field.name}", fallback, stored, multiple: field.multiple?)

          missing << field.name
        end
        next if missing.empty?

        record_required_preflight_error(row, index, unique_field,
          l(:error_import_required_fields, fields: missing.join(', ')))
      end
      report_progress(force: true)
      @messages << l(:error_import_required_preflight_abort) if @required_validation_failed
      @required_validation_failed
    end

    # A mapped empty cell must not be masked by the existing issue's value.
    # Omitted columns still support partial updates. Explicit UI defaults may
    # fill a blank cell; [CLEAR] is never replaced by a fallback.
    def required_preflight_value?(row, key, fallback, stored, multiple: false)
      column = @attrs_map[key]
      value = column.nil? ? stored : row[column]
      return false if column && clear_marker?(value)

      value = value.to_s.split(',') if multiple && value.is_a?(String)
      RequiredDefaults.present_value?(value) || RequiredDefaults.present_value?(fallback)
    end

    def record_required_preflight_error(row, index, unique_field, reason)
      @file_validation_failed = @required_validation_failed = true
      log_failure(row, reason)
      @file_validation_results << {
        row_number: index + 1, unique_value: unique_field && row[unique_field],
        subject: result_row_value(row, 'standard_field-subject'), reason: reason
      }
    end
  end
end
