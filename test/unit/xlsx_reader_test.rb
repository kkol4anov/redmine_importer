# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../lib/redmine_importer/xlsx_reader'
require_relative '../support/xlsx_fixture'

class XlsxReaderTest < Minitest::Test
  include XlsxFixture

  def read(rows, **options)
    with_xlsx(rows) do |path|
      CSV.parse(RedmineImporter::XlsxReader.new(path, **options).to_csv, headers: true)
    end
  end

  def assert_error(key, rows, **options)
    error = assert_raises(RedmineImporter::XlsxReader::Error) { read(rows, **options) }
    assert_equal key, error.key
    error
  end

  def header
    '<row r="1">' + text_cell('A1', 'Subject') + text_cell('B1', 'Value') + '</row>'
  end

  def test_unicode_quotes_multiline_and_sparse_cells
    rows = read(header + '<row r="3">' + text_cell('A3', "Тема, \"кавычки\"\nстрока") + '</row><row r="4">' + text_cell('B4', '003.0006.201') + '</row>')
    assert_equal ["Тема, \"кавычки\"\nстрока", nil], rows[0].fields
    assert_equal [nil, '003.0006.201'], rows[1].fields
  end

  def test_numbers_dates_booleans_shared_strings_and_cached_formulas
    cells = ['<c r="B2"><v>123.0</v></c>', '<c r="B3"><v>1.25</v></c>',
             '<c r="B4" s="1"><v>45292</v></c>', '<c r="B5" t="b"><v>0</v></c>',
             '<c r="B6" s="2"><v>123</v></c>', '<c r="B7"><f>1+1</f><v>2</v></c>',
             '<c r="B8" t="s"><v>0</v></c>', '<c r="B9"><v>1.2E-5</v></c>',
             '<c r="B10" s="3"><v>0.25</v></c>']
    rows = read(header + cells.each_with_index.map { |cell, i| %(<row r="#{i + 2}">#{cell}</row>) }.join)
    assert_equal ['123', '1.25', '2024-01-01', '0', '000123', '2', 'Общая строка', '0.000012', '0.25'], rows.map { |r| r['Value'] }
  end

  def test_selects_named_sheet_and_ignores_errors_in_other_sheet
    with_xlsx(header + '<row r="2"><c r="B2" t="e"><v>#REF!</v></c></row>', second_rows: header + '<row r="2">' + text_cell('A2', 'second') + '</row>') do |path|
      reader = RedmineImporter::XlsxReader.new(path, sheet_name: 'Sheet2')
      assert_equal 'second', CSV.parse(reader.to_csv, headers: true)[0]['Subject']
      assert_equal 'Sheet2', reader.sheet_name
    end
  end

  def test_1904_date_system
    with_xlsx(header + '<row r="2"><c r="B2" s="1"><v>1</v></c></row>', date1904: true) do |path|
      assert_equal '1904-01-02', CSV.parse(RedmineImporter::XlsxReader.new(path).to_csv, headers: true)[0]['Value']
    end
  end

  def test_skips_blank_rows_and_trailing_empty_formatting
    rows = read('<row r="1"/>' + header.sub('r="1"', 'r="2"') + '<row r="3"><c r="A3"/></row><row r="4">' + text_cell('A4', 'one') + '<c r="XFD4" s="1"/></row>', max_rows: 1)
    assert_equal 1, rows.size
  end

  def test_rejects_missing_or_duplicate_headers
    assert_error(:error_xlsx_headers, '<row r="1">' + text_cell('B1', 'Value') + '</row>')
    assert_error(:error_xlsx_headers, '<row r="1">' + text_cell('A1', 'Same') + text_cell('B1', ' Same ') + '</row>')
  end

  def test_rejects_empty_sheet_and_header_only
    assert_error(:error_xlsx_no_data, '')
    assert_error(:error_xlsx_no_data, header)
  end

  def test_rejects_extra_columns
    assert_error(:error_xlsx_extra_columns, header + '<row r="2">' + text_cell('C2', 'lost?') + '</row>')
  end

  def test_enforces_row_limit
    data = header + '<row r="2">' + text_cell('A2', 'one') + '</row><row r="3">' + text_cell('A3', 'two') + '</row>'
    assert_equal 2, read(data, max_rows: 2).size
    assert_error(:error_csv_row_limit_exceeded, data, max_rows: 1)
  end

  def test_rejects_uncached_formula_and_error_with_cell_address
    error = assert_error(:error_xlsx_formula, header + '<row r="2"><c r="B2"><f>1+1</f></c></row>')
    assert_equal 'B2', error.options[:cell]
    assert_error(:error_xlsx_formula, header + '<row r="2"><c r="B2"><f>1+1</f><v/></c></row>')
    assert_error(:error_xlsx_cell, header + '<row r="2"><c r="B2" t="e"><v>#DIV/0!</v></c></row>')
  end

  def test_rejects_unknown_sheet
    assert_error(:error_xlsx_sheet, header, sheet_name: 'Missing')
  end

  def test_rejects_merged_cells
    with_xlsx(header, suffix: '<mergeCells><mergeCell ref="A2:B2"/></mergeCells>') do |path|
      error = assert_raises(RedmineImporter::XlsxReader::Error) { RedmineImporter::XlsxReader.new(path).to_csv }
      assert_equal :error_xlsx_merged, error.key
    end
  end

  def test_rejects_corrupt_file
    Tempfile.create(['bad', '.xlsx']) do |file|
      file.write('not a workbook')
      file.flush
      error = assert_raises(RedmineImporter::XlsxReader::Error) { RedmineImporter::XlsxReader.new(file.path).to_csv }
      assert_equal :error_xlsx_invalid, error.key
    end
  end

  def test_rejects_data_beyond_column_limit
    assert_error(:error_xlsx_columns, header + '<row r="2">' + text_cell('XFD2', 'too far') + '</row>')
  end

  def test_bounds_normalized_csv_size_even_if_zip_is_small
    assert_error(:error_xlsx_size, header + '<row r="2">' + text_cell('A2', 'a' * (4 * 1024 * 1024)) + '</row>')
  end

  def test_rejects_oversized_upload
    Tempfile.create(['large', '.xlsx']) do |file|
      file.truncate(4 * 1024 * 1024 + 1)
      error = assert_raises(RedmineImporter::XlsxReader::Error) { RedmineImporter::XlsxReader.new(file.path).to_csv }
      assert_equal :error_xlsx_size, error.key
    end
  end

  def test_rejects_dtd_in_any_xml_part
    with_xlsx(header) do |path|
      Zip::File.open(path) do |zip|
        zip.get_output_stream('xl/sharedStrings.xml') { |stream| stream.write('<!DOCTYPE sst [<!ENTITY x "boom">]><sst/>') }
      end
      error = assert_raises(RedmineImporter::XlsxReader::Error) { RedmineImporter::XlsxReader.new(path).to_csv }
      assert_equal :error_xlsx_invalid, error.key
    end
  end
end
