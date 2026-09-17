# frozen_string_literal: true

module RedmineImporter
  # Shared by the mapping form and the importer; workflow requirements are
  # evaluated for the actual issue, status and importing user's roles.
  module RequiredDefaults
    CORE = %w[subject status_id priority_id assigned_to_id category_id
              fixed_version_id start_date due_date estimated_hours done_ratio
              description parent_issue_id is_private].freeze
    ALWAYS = %w[subject status_id priority_id].freeze
    CSV_NAMES = { 'status_id' => 'status', 'priority_id' => 'priority',
                  'assigned_to_id' => 'assigned_to', 'category_id' => 'category',
                  'fixed_version_id' => 'fixed_version',
                  'parent_issue_id' => 'parent_issue' }.freeze

    def self.required(issue)
      workflow = issue.required_attribute_names
      core = (ALWAYS + workflow).uniq & CORE
      core -= issue.disabled_core_fields
      custom = issue.available_custom_fields.select do |field|
        field.is_required? || workflow.include?(field.id.to_s)
      end.map { |field| field.id.to_s }
      [core, custom]
    end

    def self.present_value?(value)
      Array(value).any? { |item| item == false || item.to_s.strip.present? }
    end

    def self.csv_key(attribute)
      "standard_field-#{CSV_NAMES.fetch(attribute, attribute)}"
    end
  end
end
