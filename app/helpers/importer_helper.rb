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
end
