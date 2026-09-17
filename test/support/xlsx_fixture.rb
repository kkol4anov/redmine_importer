# frozen_string_literal: true

require 'zip'
require 'tempfile'
require 'cgi'

# Small OOXML packages exercise the real ZIP/XML reader, without Excel or mocks.
module XlsxFixture
  def text_cell(ref, value)
    %(<c r="#{ref}" t="inlineStr"><is><t>#{CGI.escapeHTML(value)}</t></is></c>)
  end

  def with_xlsx(rows, second_rows: nil, suffix: '', date1904: false)
    file = Tempfile.new(['importer-test', '.xlsx'])
    file.close
    sheets = [rows, second_rows].compact
    Zip::OutputStream.open(file.path) do |zip|
      parts = {
        '[Content_Types].xml' => '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="xml" ContentType="application/xml"/></Types>',
        'xl/workbook.xml' => %(<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><workbookPr date1904="#{date1904 ? 1 : 0}"/><sheets>) + sheets.each_index.map { |i| %(<sheet name="Sheet#{i + 1}" sheetId="#{i + 1}" r:id="rId#{i + 1}"/>) }.join + '</sheets></workbook>',
        'xl/_rels/workbook.xml.rels' => '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' + sheets.each_index.map { |i| %(<Relationship Id="rId#{i + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet#{i + 1}.xml"/>) }.join + '</Relationships>',
        'xl/styles.xml' => '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><numFmts count="1"><numFmt numFmtId="164" formatCode="000000"/></numFmts><cellXfs count="4"><xf numFmtId="0"/><xf numFmtId="14"/><xf numFmtId="164"/><xf numFmtId="10"/></cellXfs></styleSheet>',
        'xl/sharedStrings.xml' => '<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><si><t>Общая строка</t></si></sst>'
      }
      sheets.each_with_index do |sheet_rows, i|
        parts["xl/worksheets/sheet#{i + 1}.xml"] = '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>' + sheet_rows + '</sheetData>' + (i.zero? ? suffix : '') + '</worksheet>'
      end
      parts.each do |name, content|
        zip.put_next_entry(name)
        zip.write(content)
      end
    end
    yield file.path
  ensure
    file.unlink if file
  end
end
