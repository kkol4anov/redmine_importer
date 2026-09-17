module ImporterHelper
  # Build all panels once; switching trackers does not discard entered values
  # and requires no request racing with import submission.
  def importer_default_panels
    @project.trackers.map do |tracker|
      issue = Issue.new(project: @project, tracker: tracker, author: User.current)
      statuses = issue.new_statuses_allowed_to(User.current)
      requirements = {}
      statuses.each do |status|
        candidate = Issue.new(project: @project, tracker: tracker,
                              author: User.current, status: status)
        core, custom = RedmineImporter::RequiredDefaults.required(candidate)
        editable = candidate.editable_custom_fields.map { |field| field.id.to_s }
        requirements[status.id.to_s] = [core.select { |name| candidate.safe_attribute?(name) }, custom & editable]
      end
      requirements[issue.status_id.to_s] ||= RedmineImporter::RequiredDefaults.required(issue)
      { issue: issue, statuses: statuses, requirements: requirements }
    end
  end

  def importer_default_core_input(issue, statuses, prefix, attribute)
    name = "#{prefix}[#{attribute}]"
    id = "#{prefix.gsub(/[^a-zA-Z0-9]/, '_')}_#{attribute}"
    choices = case attribute
              when 'status_id' then statuses.map { |v| [v.name, v.id] }
              when 'priority_id' then IssuePriority.active.map { |v| [v.name, v.id] }
              when 'assigned_to_id' then issue.assignable_users.map { |v| [v.name, v.id] }
              when 'category_id' then @project.issue_categories.map { |v| [v.name, v.id] }
              when 'fixed_version_id' then issue.assignable_versions.map { |v| [v.name, v.id] }
              when 'done_ratio' then (0..10).map { |v| ["#{v * 10}%", v * 10] }
              when 'is_private' then [[l(:general_text_yes), '1'], [l(:general_text_no), '0']]
              end
    label = label_tag(id, l("field_#{attribute.delete_suffix('_id')}"))
    input = if choices
              select_tag(name, options_for_select(choices), include_blank: true, id: id,
                         class: attribute == 'status_id' ? 'import-default-status' : nil)
            elsif %w[start_date due_date].include?(attribute)
              date_field_tag(name, nil, id: id)
            elsif attribute == 'description'
              text_area_tag(name, nil, id: id, rows: 3)
            else
              text_field_tag(name, nil, id: id)
            end
    label + input
  end

  def importer_default_custom_input(issue, value)
    # Keep generated DOM IDs CSS-safe for Redmine's native widgets, while
    # grouping submitted values by tracker on the server.
    prefix = "import_defaults_#{issue.tracker_id}"
    custom_field_tag_with_label(prefix, value).gsub(
      "name=\"#{prefix}[", "name=\"required_defaults[#{issue.tracker_id}]["
    ).html_safe
  end

  def matched_attrs(column)
    matched = ''
    @attrs.each do |k,v|
      if v.to_s[/(?<=-).*/].casecmp(column.to_s.sub(" ") {|sp| "_" }) == 0 \
        || k.to_s.casecmp(column.to_s) == 0

        matched = v
      end
    end
    matched
  end

  def force_utf8(str)
    str.unpack("U*").pack('U*')
  end

  # A pop-up hint: a question-mark icon showing the explanation on hover or
  # on keyboard focus, so that the long texts do not clutter the form.
  def importer_hint(text)
    content_tag(:span, :class => 'importer-hint', :tabindex => 0) do
      content_tag(:span, '?', :class => 'importer-hint-icon', :'aria-hidden' => true) +
        content_tag(:span, text, :class => 'importer-hint-text')
    end
  end

  # The link opening the issues of a finished import in the issue list, in a
  # new tab. The ids travel in the address, so a long list is replaced by the
  # range it spans: that link is not exact (it shows whatever else appeared in
  # between), and it says so.
  def imported_issues_link(ids)
    ids = Array(ids).compact
    return nil if ids.empty?

    if ids.size <= ImporterController::RESULT_ISSUE_LIST_LINK_LIMIT
      link_to l(:label_result_open_issues),
              issues_path(:set_filter => 1, :issue_id => ids.join(',')),
              :target => '_blank', :rel => 'noopener'
    else
      first = ids.min
      last = ids.max
      link_to l(:label_result_open_issues_range, :from => first, :to => last),
              issues_path(:set_filter => 1,
                          :f => ['issue_id'],
                          :op => { 'issue_id' => '><' },
                          :v => { 'issue_id' => [first.to_s, last.to_s] }),
              :target => '_blank', :rel => 'noopener',
              :title => l(:text_result_open_issues_range_hint)
    end
  end
end
