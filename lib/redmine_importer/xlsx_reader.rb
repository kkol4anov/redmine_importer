# frozen_string_literal: true

require 'csv'
require 'date'
require 'bigdecimal'
require 'pathname'

module RedmineImporter
  # Convert one worksheet to the same representation used by the CSV importer.
  # No formulas or external links are evaluated.
  class XlsxReader
    MAX_FILE_BYTES = 4 * 1024 * 1024
    MAX_UNCOMPRESSED_BYTES = 64 * 1024 * 1024
    MAX_ENTRIES = 2000
    MAX_COLUMNS = 1024

    class Error < StandardError
      attr_reader :key, :options

      def initialize(key, **options)
        @key, @options = key, options
        super(key.to_s)
      end
    end

    attr_reader :sheet_name

    def initialize(path, sheet_name: nil, max_rows: 5000)
      @path = path
      @requested_sheet = sheet_name.to_s
      @max_rows = max_rows.to_i.positive? ? max_rows.to_i : 5000
    end

    def to_csv
      require 'roo'
      fail_with(:error_xlsx_size) if File.size(@path) > MAX_FILE_BYTES
      validate_archive
      book = Roo::Excelx.new(@path, no_hyperlinks: true, disable_html_wrapper: true)
      headers = nil
      count = 0
      result = CSV.generate(encoding: 'UTF-8') do |csv|
        book.each_row_streaming(sheet: @sheet_name) do |cells|
          row = []
          cells.each do |cell|
            next if cell.nil? || cell.empty?

            column = cell.coordinate.column
            fail_with(:error_xlsx_columns, max_columns: MAX_COLUMNS) if column > MAX_COLUMNS
            row[column - 1] = cell_text(cell)
          end
          row.pop while !row.empty? && row.last.to_s.strip.empty?
          next if row.all? { |value| value.to_s.strip.empty? }

          unless headers
            headers = row.map { |value| value.to_s.strip }
            fail_with(:error_xlsx_headers) if headers.any?(&:empty?) || headers.uniq.size != headers.size
            csv << headers
            fail_with(:error_xlsx_size) if csv.string.bytesize > MAX_FILE_BYTES
            next
          end

          fail_with(:error_xlsx_extra_columns) if row.size > headers.size
          count += 1
          if count > @max_rows
            fail_with(:error_csv_row_limit_exceeded, max_rows: @max_rows, actual_rows: count)
          end
          csv << row.fill(nil, row.size...headers.size)
          fail_with(:error_xlsx_size) if csv.string.bytesize > MAX_FILE_BYTES
        end
      end
      fail_with(:error_xlsx_no_data) if headers.nil? || count.zero?
      result
    rescue LoadError
      fail_with(:error_xlsx_dependency)
    rescue Error
      raise
    rescue StandardError
      # Do not expose archive content, server paths or parser exceptions in HTML.
      fail_with(:error_xlsx_invalid)
    ensure
      book.close if book
    end

    private

    def fail_with(key, **options)
      raise Error.new(key, **options)
    end

    def xml(zip, name)
      entry = zip.find_entry(name)
      fail_with(:error_xlsx_invalid) unless entry
      content = entry.get_input_stream.read(MAX_UNCOMPRESSED_BYTES + 1)
      fail_with(:error_xlsx_size) if content.bytesize > MAX_UNCOMPRESSED_BYTES
      fail_with(:error_xlsx_invalid) if content.match?(/<!DOCTYPE|<!ENTITY/i)
      Nokogiri::XML(content) { |config| config.strict.nonet }.remove_namespaces!
    end

    def validate_archive
      Zip::File.open(@path) do |zip|
        entries = zip.entries
        if entries.size > MAX_ENTRIES || entries.sum(&:size) > MAX_UNCOMPRESSED_BYTES
          fail_with(:error_xlsx_size)
        end
        names = entries.map(&:name)
        if names.uniq.size != names.size || names.any? { |name| name.start_with?('/') || name.split(/[\\\/]/).include?('..') }
          fail_with(:error_xlsx_invalid)
        end
        # Roo opens several XML parts, not just the selected sheet. Reject DTDs
        # before Roo parses them, and check actual decompressed sizes as well.
        total = 0
        entries.each do |entry|
          next if entry.directory?
          content = entry.get_input_stream.read(MAX_UNCOMPRESSED_BYTES - total + 1)
          total += content.bytesize
          fail_with(:error_xlsx_size) if total > MAX_UNCOMPRESSED_BYTES
          if entry.name.match?(/\.(xml|rels)\z/i) && content.match?(/<!DOCTYPE|<!ENTITY/i)
            fail_with(:error_xlsx_invalid)
          end
        end
        workbook = xml(zip, 'xl/workbook.xml')
        sheets = workbook.xpath('/workbook/sheets/sheet')
        sheet = @requested_sheet.empty? ? sheets.first : sheets.find { |item| item['name'] == @requested_sheet }
        fail_with(:error_xlsx_sheet, sheet: @requested_sheet) unless sheet
        @sheet_name = sheet['name']
        relationships = xml(zip, 'xl/_rels/workbook.xml.rels')
        relationship = relationships.xpath('/Relationships/Relationship').find { |item| item['Id'] == sheet['id'] }
        unless relationship && relationship['Type'].to_s.end_with?('/worksheet') && relationship['TargetMode'] != 'External'
          fail_with(:error_xlsx_invalid)
        end
        target = relationship['Target'].to_s
        path = target.start_with?('/') ? target.delete_prefix('/') : Pathname.new("xl/#{target}").cleanpath.to_s
        document = xml(zip, path)
        fail_with(:error_xlsx_merged) if document.at_xpath('/worksheet/mergeCells/mergeCell')
        document.xpath('/worksheet/sheetData/row/c').each do |cell|
          fail_with(:error_xlsx_cell, cell: cell['r']) if cell['t'] == 'e'
          value = cell.at_xpath('v')
          if cell.at_xpath('f') && (value.nil? || (value.content.empty? && cell['t'] != 'str'))
            fail_with(:error_xlsx_formula, cell: cell['r'])
          end
        end
      end
    end

    def cell_text(cell)
      value = cell.value
      case value
      when DateTime, Time then value.strftime('%Y-%m-%d %H:%M:%S')
      when Date then value.iso8601
      when true then '1'
      when false then '0'
      when Numeric
        return cell.formatted_value if cell.respond_to?(:format) && cell.format.to_s.match?(/\A0{2,}\z/)
        return format('%02d:%02d:%02d', value / 3600, (value / 60) % 60, value % 60) if cell.default_type == :time

        # Use XML's decimal value rather than round-tripping through Float.
        BigDecimal(cell.cell_value.to_s).to_s('F').sub(/\.0+\z/, '').sub(/(\.\d*?)0+\z/, '\\1')
      else value.to_s
      end
    end
  end
end
