module ImporterHelper
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
