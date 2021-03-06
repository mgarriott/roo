# encoding: utf-8

require 'tmpdir'
require 'stringio'
require 'nokogiri'
require 'roo/utils'

# Base class for all other types of spreadsheets
class Roo::Base
  include Enumerable

  TEMP_PREFIX = 'roo_'
  MAX_ROW_COL = 999_999.freeze
  MIN_ROW_COL = 0.freeze

  attr_reader :headers

  # sets the line with attribute names (default: 1)
  attr_accessor :header_line

  class << self

  end

  def initialize(filename, options = {}, _file_warning = :error, _tmpdir = nil)
    @filename = filename
    @options = options

    @cell = {}
    @cell_type = {}
    @cells_read = {}

    @first_row = {}
    @last_row = {}
    @first_column = {}
    @last_column = {}

    @header_line = 1
  end

  def default_sheet
    @default_sheet ||= sheets.first
  end

  # sets the working sheet in the document
  # 'sheet' can be a number (1 = first sheet) or the name of a sheet.
  def default_sheet=(sheet)
    validate_sheet!(sheet)
    @default_sheet = sheet
    @first_row[sheet] = @last_row[sheet] = @first_column[sheet] = @last_column[sheet] = nil
    @cells_read[sheet] = false
  end

  # first non-empty column as a letter
  def first_column_as_letter(sheet = default_sheet)
    ::Roo::Utils.number_to_letter(first_column(sheet))
  end

  # last non-empty column as a letter
  def last_column_as_letter(sheet = default_sheet)
    ::Roo::Utils.number_to_letter(last_column(sheet))
  end

  # Set first/last row/column for sheet
  def first_last_row_col_for_sheet(sheet)
    @first_last_row_cols ||= {}
    @first_last_row_cols[sheet] ||= begin
      result = collect_last_row_col_for_sheet(sheet)
      {
        first_row: result[:first_row] == MAX_ROW_COL ? nil : result[:first_row],
        first_column: result[:first_column] == MAX_ROW_COL ? nil : result[:first_column],
        last_row: result[:last_row] == MIN_ROW_COL ? nil : result[:last_row],
        last_column: result[:last_column] == MIN_ROW_COL ? nil : result[:last_column]
      }
    end
  end

  # Collect first/last row/column from sheet
  def collect_last_row_col_for_sheet(sheet)
    first_row = first_column = MAX_ROW_COL
    last_row = last_column = MIN_ROW_COL
    @cell[sheet].each_pair do|key, value|
      next unless value
      first_row = [first_row, key.first.to_i].min
      last_row = [last_row, key.first.to_i].max
      first_column = [first_column, key.last.to_i].min
      last_column = [last_column, key.last.to_i].max
    end if @cell[sheet]
    {first_row: first_row, first_column: first_column, last_row: last_row, last_column: last_column}
  end

  %w(first_row last_row first_column last_column).each do |key|
    class_eval <<-EOS, __FILE__, __LINE__ + 1
      def #{key}(sheet = default_sheet)                                   # def first_row(sheet = default_sheet)
        read_cells(sheet)                                                 #   read_cells(sheet)
        @#{key}[sheet] ||= first_last_row_col_for_sheet(sheet)[:#{key}]   #   @first_row[sheet] ||= first_last_row_col_for_sheet(sheet)[:first_row]
      end                                                                 # end
    EOS
  end

  # returns a rectangular area (default: all cells) as yaml-output
  # you can add additional attributes with the prefix parameter like:
  # oo.to_yaml({"file"=>"flightdata_2007-06-26", "sheet" => "1"})
  def to_yaml(prefix = {}, from_row = nil, from_column = nil, to_row = nil, to_column = nil, sheet = default_sheet)
    return '' unless first_row # empty result if there is no first_row in a sheet

    from_row ||= first_row(sheet)
    to_row ||= last_row(sheet)
    from_column ||= first_column(sheet)
    to_column ||= last_column(sheet)

    result = "--- \n"
    from_row.upto(to_row) do |row|
      from_column.upto(to_column) do |col|
        unless empty?(row, col, sheet)
          result << "cell_#{row}_#{col}: \n"
          prefix.each do|k, v|
            result << "  #{k}: #{v} \n"
          end
          result << "  row: #{row} \n"
          result << "  col: #{col} \n"
          result << "  celltype: #{celltype(row, col, sheet)} \n"
          value = cell(row, col, sheet)
          if celltype(row, col, sheet) == :time
            value = integer_to_timestring(value)
          end
          result << "  value: #{value} \n"
        end
      end
    end
    result
  end

  # write the current spreadsheet to stdout or into a file
  def to_csv(filename = nil, separator = ',', sheet = default_sheet)
    if filename
      File.open(filename, 'w') do |file|
        write_csv_content(file, sheet, separator)
      end
      true
    else
      sio = ::StringIO.new
      write_csv_content(sio, sheet, separator)
      sio.rewind
      sio.read
    end
  end

  # returns a matrix object from the whole sheet or a rectangular area of a sheet
  def to_matrix(from_row = nil, from_column = nil, to_row = nil, to_column = nil, sheet = default_sheet)
    require 'matrix'

    return Matrix.empty unless first_row

    from_row ||= first_row(sheet)
    to_row ||= last_row(sheet)
    from_column ||= first_column(sheet)
    to_column ||= last_column(sheet)

    Matrix.rows(from_row.upto(to_row).map do |row|
      from_column.upto(to_column).map do |col|
        cell(row, col, sheet)
      end
    end)
  end

  # call to_s method defined on subclasses
  def inspect
    to_s
  end

  # find a row either by row number or a condition
  # Caution: this works only within the default sheet -> set default_sheet before you call this method
  # (experimental. see examples in the test_roo.rb file)
  def find(*args) # :nodoc
    options = (args.last.is_a?(Hash) ? args.pop : {})

    case args[0]
    when Fixnum
      find_by_row(args[0])
    when :all
      find_by_conditions(options)
    else
      fail ArgumentError, "unexpected arg #{args[0].inspect}, pass a row index or :all"
    end
  end

  # returns all values in this row as an array
  # row numbers are 1,2,3,... like in the spreadsheet
  def row(row_number, sheet = default_sheet)
    read_cells(sheet)
    first_column(sheet).upto(last_column(sheet)).map do |col|
      cell(row_number, col, sheet)
    end
  end

  # returns all values in this column as an array
  # column numbers are 1,2,3,... like in the spreadsheet
  def column(column_number, sheet = default_sheet)
    if column_number.is_a?(::String)
      column_number = ::Roo::Utils.letter_to_number(column_number)
    end
    read_cells(sheet)
    first_row(sheet).upto(last_row(sheet)).map do |row|
      cell(row, column_number, sheet)
    end
  end

  # set a cell to a certain value
  # (this will not be saved back to the spreadsheet file!)
  def set(row, col, value, sheet = default_sheet) #:nodoc:
    read_cells(sheet)
    row, col = normalize(row, col)
    cell_type = cell_type_by_value(value)
    set_value(row, col, value, sheet)
    set_type(row, col, cell_type , sheet)
  end

  def cell_type_by_value(value)
    case value
    when Fixnum then :float
    when String, Float then :string
    else
      raise ArgumentError, "Type for #{value} not set"
    end
  end

  # reopens and read a spreadsheet document
  def reload
    ds = default_sheet
    reinitialize
    self.default_sheet = ds
  end

  # true if cell is empty
  def empty?(row, col, sheet = default_sheet)
    read_cells(sheet)
    row, col = normalize(row, col)
    contents = cell(row, col, sheet)
    !contents || (celltype(row, col, sheet) == :string && contents.empty?) \
      || (row < first_row(sheet) || row > last_row(sheet) || col < first_column(sheet) || col > last_column(sheet))
  end

  # returns information of the spreadsheet document and all sheets within
  # this document.
  def info
    without_changing_default_sheet do
      result = "File: #{File.basename(@filename)}\n"\
        "Number of sheets: #{sheets.size}\n"\
        "Sheets: #{sheets.join(', ')}\n"
      n = 1
      sheets.each do|sheet|
        self.default_sheet = sheet
        result << 'Sheet ' + n.to_s + ":\n"
        unless first_row
          result << '  - empty -'
        else
          result << "  First row: #{first_row}\n"
          result << "  Last row: #{last_row}\n"
          result << "  First column: #{::Roo::Utils.number_to_letter(first_column)}\n"
          result << "  Last column: #{::Roo::Utils.number_to_letter(last_column)}"
        end
        result << "\n" if sheet != sheets.last
        n += 1
      end
      result
    end
  end

  # returns an XML representation of all sheets of a spreadsheet file
  def to_xml
    Nokogiri::XML::Builder.new do |xml|
      xml.spreadsheet do
        sheets.each do |sheet|
          self.default_sheet = sheet
          xml.sheet(name: sheet) do |x|
            if first_row && last_row && first_column && last_column
              # sonst gibt es Fehler bei leeren Blaettern
              first_row.upto(last_row) do |row|
                first_column.upto(last_column) do |col|
                  unless empty?(row, col)
                    x.cell(cell(row, col),
                           row: row,
                           column: col,
                           type: celltype(row, col))
                  end
                end
              end
            end
          end
        end
      end
    end.to_xml
  end

  # when a method like spreadsheet.a42 is called
  # convert it to a call of spreadsheet.cell('a',42)
  def method_missing(m, *args)
    # #aa42 => #cell('aa',42)
    # #aa42('Sheet1')  => #cell('aa',42,'Sheet1')
    if m =~ /^([a-z]+)(\d)$/
      col = ::Roo::Utils.letter_to_number(Regexp.last_match[1])
      row = Regexp.last_match[2].to_i
      if args.empty?
        cell(row, col)
      else
        cell(row, col, args.first)
      end
    else
      super
    end
  end

  # access different worksheets by calling spreadsheet.sheet(1)
  # or spreadsheet.sheet('SHEETNAME')
  def sheet(index, name = false)
    self.default_sheet = String === index ? index : sheets[index]
    name ? [default_sheet, self] : self
  end

  # iterate through all worksheets of a document
  def each_with_pagename
    sheets.each do |s|
      yield sheet(s, true)
    end
  end


  def clean_sheet_if_need(options)
    return unless options[:clean]
    options.delete(:clean)
    @cleaned ||= {}
    clean_sheet(default_sheet) unless @cleaned[default_sheet]
  end

  def search_or_set_header(options)
    if options[:header_search]
      @headers = nil
      @header_line = row_with(options[:header_search])
    elsif [:first_row, true].include?(options[:headers])
      @headers = []
      row(first_row).each_with_index { |x, i| @headers << [x, i + 1] }
    else
      set_headers(options)
    end
  end

  # by passing in headers as options, this method returns
  # specific columns from your header assignment
  # for example:
  # xls.sheet('New Prices').parse(:upc => 'UPC', :price => 'Price') would return:
  # [{:upc => 123456789012, :price => 35.42},..]

  # the queries are matched with regex, so regex options can be passed in
  # such as :price => '^(Cost|Price)'
  # case insensitive by default

  # by using the :header_search option, you can query for headers
  # and return a hash of every row with the keys set to the header result
  # for example:
  # xls.sheet('New Prices').parse(:header_search => ['UPC*SKU','^Price*\sCost\s'])

  # that example searches for a column titled either UPC or SKU and another
  # column titled either Price or Cost (regex characters allowed)
  # * is the wildcard character

  # you can also pass in a :clean => true option to strip the sheet of
  # odd unicode characters and white spaces around columns

  def each(options = {})
    if options.empty?
      1.upto(last_row) do |line|
        yield row(line)
      end
    else
      clean_sheet_if_need(options)
      search_or_set_header(options)
      headers = @headers ||
                Hash[(first_column..last_column).map do |col|
                  [cell(@header_line, col), col]
                end]

      @header_line.upto(last_row) do |line|
        yield(Hash[headers.map { |k, v| [k, cell(line, v)] }])
      end
    end
  end

  def parse(options = {})
    ary = []
    each(options) do |row|
      yield(row) if block_given?
      ary << row
    end
    ary
  end

  def row_with(query, return_headers = false)
    query.map! { |x| Array(x.split('*')) }
    line_no = 0
    each do |row|
      line_no += 1
      # makes sure headers is the first part of wildcard search for priority
      # ex. if UPC and SKU exist for UPC*SKU search, UPC takes the cake
      headers = query.map do |q|
        q.map { |i| row.grep(/#{i}/i)[0] }.compact[0]
      end.compact

      if headers.length == query.length
        @header_line = line_no
        return return_headers ? headers : line_no
      elsif line_no > 100
        fail "Couldn't find header row."
      end
    end
    fail "Couldn't find header row."
  end

  protected

  def file_type_check(filename, ext, name, warning_level, packed = nil)
    if packed == :zip
      # lalala.ods.zip => lalala.ods
      # hier wird KEIN unzip gemacht, sondern nur der Name der Datei
      # getestet, falls es eine gepackte Datei ist.
      filename = File.basename(filename, File.extname(filename))
    end

    if uri?(filename) && qs_begin = filename.rindex('?')
      filename = filename[0..qs_begin - 1]
    end
    if File.extname(filename).downcase != ext
      case warning_level
      when :error
        warn file_type_warning_message(filename, ext)
        fail TypeError, "#{filename} is not #{name} file"
      when :warning
        warn "are you sure, this is #{name} spreadsheet file?"
        warn file_type_warning_message(filename, ext)
      when :ignore
        # ignore
      else
        fail "#{warning_level} illegal state of file_warning"
      end
    end
  end

  # konvertiert einen Key in der Form "12,45" (=row,column) in
  # ein Array mit numerischen Werten ([12,45])
  # Diese Methode ist eine temp. Loesung, um zu erforschen, ob der
  # Zugriff mit numerischen Keys schneller ist.
  def key_to_num(str)
    r, c = str.split(',')
    [r.to_i, c.to_i]
  end

  # see: key_to_num
  def key_to_string(arr)
    "#{arr[0]},#{arr[1]}"
  end

  private

  def local_filename(filename, tmpdir, packed)
    filename = download_uri(filename, tmpdir) if uri?(filename)
    filename = unzip(filename, tmpdir) if packed == :zip
    unless File.file?(filename)
      fail IOError, "file #{filename} does not exist"
    end
    filename
  end

  def file_type_warning_message(filename, ext)
    "use #{Roo::CLASS_FOR_EXTENSION.fetch(ext.sub('.', '').to_sym)}.new to handle #{ext} spreadsheet files. This has #{File.extname(filename).downcase}"
  rescue KeyError
    raise "unknown file type: #{ext}"
  end

  def find_by_row(row_index)
    row_index += (header_line - 1) if @header_line

    row(row_index).size.times.map do |cell_index|
      cell(row_index, cell_index + 1)
    end
  end

  def find_by_conditions(options)
    rows = first_row.upto(last_row)
    header_for = Hash[1.upto(last_column).map do |col|
      [col, cell(@header_line, col)]
    end]

    # are all conditions met?
    conditions = options[:conditions]
    if conditions && !conditions.empty?
      column_with = header_for.invert
      rows = rows.select do |i|
        conditions.all? { |key, val| cell(i, column_with[key]) == val }
      end
    end

    if options[:array]
      rows.map { |i| row(i) }
    else
      rows.map do |i|
        Hash[1.upto(row(i).size).map do |j|
          [header_for.fetch(j), cell(i, j)]
        end]
      end
    end
  end

  def without_changing_default_sheet
    original_default_sheet = default_sheet
    yield
  ensure
    self.default_sheet = original_default_sheet
  end

  def reinitialize
    initialize(@filename)
  end

  def make_tmpdir(prefix = nil, root = nil, &block)
    prefix = if prefix
      TEMP_PREFIX + prefix
    else
      TEMP_PREFIX
    end
    Dir.mktmpdir(prefix, root || ENV['ROO_TMP'], &block)
  end

  def clean_sheet(sheet)
    read_cells(sheet)
    @cell[sheet].each_pair do |coord, value|
      if value.is_a?(::String)
        @cell[sheet][coord] = sanitize_value(value)
      end
    end
    @cleaned[sheet] = true
  end

  def sanitize_value(v)
    v.unpack('U*').select { |b| b < 127 }.pack('U*').strip
  end

  def set_headers(hash = {})
    # try to find header row with all values or give an error
    # then create new hash by indexing strings and keeping integers for header array
    @headers = row_with(hash.values, true)
    @headers = Hash[hash.keys.zip(@headers.map { |x| header_index(x) })]
  end

  def header_index(query)
    row(@header_line).index(query) + first_column
  end

  def set_value(row, col, value, sheet = default_sheet)
    @cell[sheet][[row, col]] = value
  end

  def set_type(row, col, type, sheet = default_sheet)
    @cell_type[sheet][[row, col]] = type
  end

  # converts cell coordinate to numeric values of row,col
  def normalize(row, col)
    if row.is_a?(::String)
      if col.is_a?(::Fixnum)
        # ('A',1):
        # ('B', 5) -> (5, 2)
        row, col = col, row
      else
        fail ArgumentError
      end
    end
    if col.is_a?(::String)
      col = ::Roo::Utils.letter_to_number(col)
    end
    [row, col]
  end

  def uri?(filename)
    filename.start_with?('http://', 'https://')
  rescue
    false
  end

  def download_uri(uri, tmpdir)
    require 'open-uri'
    tempfilename = File.join(tmpdir, File.basename(uri))
    begin
      File.open(tempfilename, 'wb') do |file|
        open(uri, 'User-Agent' => "Ruby/#{RUBY_VERSION}") do |net|
          file.write(net.read)
        end
      end
    rescue OpenURI::HTTPError
      raise "could not open #{uri}"
    end
    tempfilename
  end

  def open_from_stream(stream, tmpdir)
    tempfilename = File.join(tmpdir, 'spreadsheet')
    File.open(tempfilename, 'wb') do |file|
      file.write(stream[7..-1])
    end
    File.join(tmpdir, 'spreadsheet')
  end

  def unzip(filename, tmpdir)
    require 'zip/filesystem'

    Zip::File.open(filename) do |zip|
      process_zipfile_packed(zip, tmpdir)
    end
  end

  # check if default_sheet was set and exists in sheets-array
  def validate_sheet!(sheet)
    case sheet
    when nil
      fail ArgumentError, "Error: sheet 'nil' not valid"
    when Fixnum
      sheets.fetch(sheet - 1) do
        fail RangeError, "sheet index #{sheet} not found"
      end
    when String
      unless sheets.include? sheet
        fail RangeError, "sheet '#{sheet}' not found"
      end
    else
      fail TypeError, "not a valid sheet type: #{sheet.inspect}"
    end
  end

  def process_zipfile_packed(zip, tmpdir, path = '')
    if zip.file.file? path
      # extract and return filename
      File.open(File.join(tmpdir, path), 'wb') do |file|
        file.write(zip.read(path))
      end
      File.join(tmpdir, path)
    else
      ret = nil
      path += '/' unless path.empty?
      zip.dir.foreach(path) do |filename|
        ret = process_zipfile_packed(zip, tmpdir, path + filename)
      end
      ret
    end
  end

  # Write all cells to the csv file. File can be a filename or nil. If the this
  # parameter is nil the output goes to STDOUT
  def write_csv_content(file = nil, sheet = nil, separator = ',')
    file ||= STDOUT
    if first_row(sheet) # sheet is not empty
      1.upto(last_row(sheet)) do |row|
        1.upto(last_column(sheet)) do |col|
          file.print(separator) if col > 1
          file.print cell_to_csv(row, col, sheet)
        end
        file.print("\n")
      end # sheet not empty
    end
  end

  # The content of a cell in the csv output
  def cell_to_csv(row, col, sheet)
    if empty?(row, col, sheet)
      ''
    else
      onecell = cell(row, col, sheet)

      case celltype(row, col, sheet)
      when :string
        %("#{onecell.tr('"', '""')}") unless onecell.empty?
      when :boolean
        %("#{onecell.tr('"', '""').downcase}")
      when :float, :percentage
        if onecell == onecell.to_i
          onecell.to_i.to_s
        else
          onecell.to_s
        end
      when :formula
        case onecell
        when String
          %("#{onecell.tr('"', '""')}") unless onecell.empty?
        when Float
          if onecell == onecell.to_i
            onecell.to_i.to_s
          else
            onecell.to_s
          end
        when DateTime
          onecell.to_s
        else
          fail "unhandled onecell-class #{onecell.class}"
        end
      when :date, :datetime
        onecell.to_s
      when :time
        integer_to_timestring(onecell)
      when :link
        %("#{onecell.url.tr('"', '""')}")
      else
        fail "unhandled celltype #{celltype(row, col, sheet)}"
      end || ''
    end
  end

  private

  # converts an integer value to a time string like '02:05:06'
  def integer_to_timestring(content)
    h = (content / 3600.0).floor
    content = content - h * 3600
    m = (content / 60.0).floor
    content = content - m * 60
    s = content
    sprintf('%02d:%02d:%02d', h, m, s)
  end
end
