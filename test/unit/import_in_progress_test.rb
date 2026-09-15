require File.dirname(__FILE__) + '/../test_helper'

class ImportInProgressTest < ActiveSupport::TestCase
  def setup
    @admin = User.new(admin: true,
                      login: 'admin_settings_test',
                      firstname: 'Admin',
                      lastname: 'User',
                      mail: 'admin_settings_test@example.com')
    Mailer.stubs(:deliver_security_notification)
    @admin.save!
    User.stubs(:current).returns(@admin)
  end

  test 'encode_csv_data stores bytes that are valid UTF-8 regardless of column encoding tag' do
    iip = ImportInProgress.new(encoding: 'U', col_sep: ',', quote_char: '"', created: Time.current, user: @admin)
    iip.csv_data = "id,subject\n1,test\n".force_encoding('ASCII-8BIT')
    iip.save!
    assert iip.csv_data.dup.force_encoding('UTF-8').valid_encoding?
  end

  test 'encode_csv_data replaces invalid sequences instead of raising' do
    iip = ImportInProgress.new(encoding: 'U', col_sep: ',', quote_char: '"', created: Time.current, user: @admin)
    iip.csv_data = "id,subject\n1,\x82\xC4\x82\xB7\x82\xC6\n".force_encoding('ASCII-8BIT')
    assert_nothing_raised { iip.save! }
    assert iip.csv_data.dup.force_encoding('UTF-8').valid_encoding?
  end

  test 'encode_csv_data correctly converts Shift-JIS to UTF-8 bytes when encoding is S' do
    iip = ImportInProgress.new(encoding: 'S', col_sep: ',', quote_char: '"', created: Time.current, user: @admin)
    sjis_data = "id,件名\n1,テスト\n".encode('Shift_JIS')
    iip.csv_data = sjis_data
    iip.save!
    utf8_retagged = iip.csv_data.dup.force_encoding('UTF-8')
    assert utf8_retagged.valid_encoding?
    assert utf8_retagged.include?('テスト')
  end

  test 'only one request can claim an import' do
    iip = ImportInProgress.create!(encoding: 'U', col_sep: ',', quote_char: '"',
                                   created: Time.current, user: @admin,
                                   csv_data: "id,subject\n1,test\n")

    assert iip.claim!('first-request')
    assert_not iip.claim!('second-request')
    assert_equal 'first-request', iip.reload.run_token
  end

  test 'only the request that claimed an import can cancel it' do
    iip = ImportInProgress.create!(encoding: 'U', col_sep: ',', quote_char: '"',
                                   created: Time.current, user: @admin,
                                   csv_data: "id,subject\n1,test\n")
    assert iip.claim!('owner')

    assert_not iip.request_cancel!('stale-tab')
    assert_nil iip.reload.cancel_requested_at
    assert iip.request_cancel!('owner')
    assert iip.cancel_requested?
  end

  test 'cancelled is a final stage' do
    iip = ImportInProgress.new(stage: ImportInProgress::STAGE_CANCELLED)
    assert iip.finished?
    assert_equal 100, iip.percent_complete
  end
end
