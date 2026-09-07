# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

class ImporterControllerTest < ActionController::TestCase
  include ActiveJob::TestHelper

  fixtures :users

  def setup
    ActionController::Base.allow_forgery_protection = false
    @project = Project.create! name: 'foo', identifier: 'importer_controller_test'
    @tracker = Tracker.new(name: 'Defect')
    @tracker.default_status = IssueStatus.find_or_create_by!(name: 'New')
    @tracker.save!
    @project.trackers << @tracker
    @project.save!
    @role = Role.create! name: 'ADMIN', permissions: %i[import view_issues]
    @user = create_user!(@role, @project)
    @iip = create_iip_for_multivalues!(@user, @project)
    @issue = create_issue!(@project, @user, { id: 70_385, tracker: @tracker })
    create_custom_fields!(@issue)
    create_versions!(@project)
    User.stubs(:current).returns(@user)
  end

  test 'should handle multiple values for versions' do
    assert issue_has_none_of_these_multival_versions?(@issue,
                                                      %w[Admin 2013-09-25])
    post :result, params: build_params(update_issue: 'true')
    assert_response :success
    @issue.reload
    assert issue_has_all_these_multival_versions?(@issue, %w[Admin 2013-09-25])
  end

  test 'should handle multiple values' do
    assert issue_has_none_of_these_multifield_vals?(@issue, %w[tag1 tag2])
    post :result, params: build_params(update_issue: 'true')
    assert_response :success
    @issue.reload
    assert issue_has_all_these_multifield_vals?(@issue, %w[tag1 tag2])
  end

  test 'should handle single-value fields' do
    assert_equal 'foobar', @issue.subject
    post :result, params: build_params(update_issue: 'true')
    assert_response :success
    @issue.reload
    assert_equal 'barfooz', @issue.subject
    assert_equal @user.today, @issue.start_date
  end

  test 'should reject csv exceeding row limit' do
    # Set max row limit to 2
    Setting.stubs(:plugin_redmine_importer).returns({ 'max_csv_rows' => '2' })

    # Create CSV with more than 2 data rows
    csv_data = "id,subject,tracker\n"
    csv_data += "1,Issue 1,Bug\n"
    csv_data += "2,Issue 2,Bug\n"
    csv_data += "3,Issue 3,Bug\n" # This makes it 3 data rows

    file = Tempfile.new(['test', '.csv'])
    file.write(csv_data)
    file.rewind

    post :match, params: {
      project_id: @project.identifier,
      file: Rack::Test::UploadedFile.new(file.path, 'text/csv'),
      wrapper: '"',
      splitter: ',',
      encoding: 'UTF-8'
    }

    assert_redirected_to project_importer_path(project_id: @project.identifier)
    assert flash[:error].include?('exceeds the maximum allowed rows')
    assert flash[:error].include?('Maximum: 2')
    assert flash[:error].include?('Actual: 3')
  ensure
    file.close
    file.unlink
  end

  test 'should accept csv within row limit' do
    # Set max row limit to 5
    Setting.stubs(:plugin_redmine_importer).returns({ 'max_csv_rows' => '5' })

    # Create CSV with 2 data rows
    csv_data = "id,subject,tracker\n"
    csv_data += "1,Issue 1,Bug\n"
    csv_data += "2,Issue 2,Bug\n"

    file = Tempfile.new(['test', '.csv'])
    file.write(csv_data)
    file.rewind

    post :match, params: {
      project_id: @project.identifier,
      file: Rack::Test::UploadedFile.new(file.path, 'text/csv'),
      wrapper: '"',
      splitter: ',',
      encoding: 'UTF-8'
    }

    assert_response :success
    assert_nil flash[:error]
  ensure
    file.close
    file.unlink
  end

  test 'should create issue if none exists' do
    Mailer.expects(:deliver_issue_add).never
    Issue.delete_all
    assert_equal 0, Issue.count
    post :result, params: build_params
    assert_response :success
    assert_equal 1, Issue.count
    issue = Issue.first
    assert_equal 'barfooz', issue.subject
  end

  test 'should send email when Send email notifications checkbox is checked and issue updated' do
    assert_equal 'foobar', @issue.subject
    Mailer.expects(:deliver_issue_edit)

    post :result, params: build_params(update_issue: 'true', send_emails: 'true')
    assert_response :success
    @issue.reload
    assert_equal 'barfooz', @issue.subject
  end

  test 'should send email when Send email notifications checkbox is checked and issue added' do
    assert_equal 'foobar', @issue.subject
    Mailer.expects(:deliver_issue_add)

    assert_equal 0, Issue.where(subject: 'barfooz').count
    post :result, params: build_params(send_emails: 'true')
    assert_response :success
    assert_equal 1, Issue.where(subject: 'barfooz').count
  end

  test 'should NOT send email when Send email notifications checkbox is unchecked' do
    assert_equal 'foobar', @issue.subject
    Mailer.expects(:deliver_issue_edit).never

    post :result, params: build_params(update_issue: 'true')
    assert_response :success
    @issue.reload
    assert_equal 'barfooz', @issue.subject
  end

  test 'should add watchers' do
    assert issue_has_none_of_these_watchers?(@issue, [@user])
    post :result, params: build_params(update_issue: 'true')
    assert_response :success
    @issue.reload
    assert issue_has_all_of_these_watchers?(@issue, [@user])
  end

  test 'should handle key value list value' do
    Mailer.expects(:deliver_issue_add).never
    IssueCustomField.where(name: 'Area').each { |icf| icf.update(multiple: false) }
    @iip.destroy
    @iip = create_iip!('KeyValueList', @user, @project)
    post :result, params: build_params
    assert_response :success
    assert keyval_vals_for(Issue.find_by!(subject: 'パンケーキ')) == ['Tokyo']
    assert keyval_vals_for(Issue.find_by!(subject: 'たこ焼き')) == ['Osaka']
    assert Issue.find_by(subject: 'サーターアンダギー').nil?
  end

  test 'should handle multiple key value list values' do
    Mailer.expects(:deliver_issue_add).never
    @iip.destroy
    @iip = create_iip!('KeyValueListMultiple', @user, @project)
    post :result, params: build_params
    assert_response :success
    assert keyval_vals_for(Issue.find_by!(subject: 'パンケーキ')) == ['Tokyo']
    assert keyval_vals_for(Issue.find_by!(subject: 'たこ焼き')) == ['Osaka']
    issue = Issue.find_by!(subject: 'タピオカ')
    assert(%w[Tokyo Osaka].all? { |area| area.in?(keyval_vals_for(Issue.find_by!(subject: 'タピオカ'))) })
    assert Issue.find_by(subject: 'サーターアンダギー').nil?
  end

  test 'should handle issue relation' do
    other_issue = create_issue!(@project, @user, { subject: 'other_issue' })
    @iip.update!(csv_data: "#,Subject,Duplicated issue ID\n#{@issue.id},set other issue relation,#{other_issue.id}\n")
    post :result, params: build_params(update_issue: 'true', use_issue_id: '1').tap { |params|
                            params[:fields_map]['Duplicated issue ID'] = "issue_relation-#{IssueRelation::TYPE_DUPLICATED}"
                          }
    assert_response :success
    @issue.reload
    assert_equal 'set other issue relation', @issue.subject
    issue_relation = @issue.relations_to.first!
    assert_equal other_issue, issue_relation.issue_from
    assert_equal IssueRelation::TYPE_DUPLICATES, issue_relation.relation_type
    assert_equal 1, @issue.relations_to.count
  end

  test 'should handle parent issue defined after child in CSV using # column as unique key' do
    # CSV: Child issue (#=1, parent=2) comes before Parent issue (#=2)
    # Uses sequential numbers in # column as internal CSV reference (not DB ID)
    @iip.update!(csv_data: "#,Subject,Tracker,Status,Priority,Parent\n1,Child Issue,Defect,New,Critical,2\n2,Parent Issue,Defect,New,Critical,\n")
    post :result, params: {
      import_timestamp: @iip.created.strftime('%Y-%m-%d %H:%M:%S'),
      unique_field: '#',
      project_id: @project.id,
      fields_map: {
        '#' => 'standard_field-id',
        'Subject' => 'standard_field-subject',
        'Tracker' => 'standard_field-tracker',
        'Status' => 'standard_field-status',
        'Priority' => 'standard_field-priority',
        'Parent' => 'standard_field-parent_issue'
      }
    }
    assert_response :success
    assert !response.body.include?('Warning'), "Unexpected warning in response"

    child = Issue.find_by!(subject: 'Child Issue')
    parent = Issue.find_by!(subject: 'Parent Issue')
    assert_equal parent.id, child.parent_id
  end

  test 'should handle issue relation defined later in CSV with empty values skipped' do
    # CSV: #=2 comes first and references #=1 which comes later (descending order)
    # This matches Redmine export format where newer issues appear first
    # #=1 has empty relation value which should be skipped without warning
    @iip.update!(csv_data: "#,Subject,Tracker,Status,Priority,Related issue\n2,Issue Two,Defect,New,Critical,1\n1,Issue One,Defect,New,Critical,\"\"\n")
    post :result, params: {
      import_timestamp: @iip.created.strftime('%Y-%m-%d %H:%M:%S'),
      unique_field: '#',
      project_id: @project.id,
      fields_map: {
        '#' => 'standard_field-id',
        'Subject' => 'standard_field-subject',
        'Tracker' => 'standard_field-tracker',
        'Status' => 'standard_field-status',
        'Priority' => 'standard_field-priority',
        'Related issue' => "issue_relation-#{IssueRelation::TYPE_RELATES}"
      }
    }
    assert_response :success
    assert !response.body.include?('Warning'), "Unexpected warning: #{response.body}"

    issue_one = Issue.find_by!(subject: 'Issue One')
    issue_two = Issue.find_by!(subject: 'Issue Two')
    # issue_two should have a relation to issue_one (deferred resolution worked)
    assert_equal 1, issue_two.relations.count, "Expected issue_two to have 1 relation"
    relation = issue_two.relations.first
    assert_equal issue_one.id, relation.other_issue(issue_two).id
  end

  test 'should warn when deferred reference target is not found in CSV' do
    # CSV: Child issue references parent "999" which doesn't exist in CSV
    @iip.update!(csv_data: "#,Subject,Tracker,Status,Priority,Parent\n1,Orphan Issue,Defect,New,Critical,999\n")
    post :result, params: {
      import_timestamp: @iip.created.strftime('%Y-%m-%d %H:%M:%S'),
      unique_field: '#',
      project_id: @project.id,
      fields_map: {
        '#' => 'standard_field-id',
        'Subject' => 'standard_field-subject',
        'Tracker' => 'standard_field-tracker',
        'Status' => 'standard_field-status',
        'Priority' => 'standard_field-priority',
        'Parent' => 'standard_field-parent_issue'
      }
    }
    assert_response :success
    assert response.body.include?('Warning')
    assert response.body.include?('999')
    assert response.body.include?('never resolved')

    orphan = Issue.find_by!(subject: 'Orphan Issue')
    assert_nil orphan.parent_id
  end

  test 'should error when assigned_to is missing' do
    @iip.update!(csv_data: "#,Subject,assigned_to\n#{@issue.id},barfooz,JohnDoe\n")
    @issue.reload.update!(assigned_to: @user)
    post :result, params: build_params(update_issue: 'true').tap { |params|
                            params[:fields_map]['assigned_to'] = 'standard_field-assigned_to'
                          }
    assert_response :success
    assert response.body.include?('Warning')
    @issue.reload
    assert_equal 'foobar', @issue.subject
    assert_equal @user, @issue.assigned_to
  end

  test 'should unset assigned_to when assigned_to user is not assignable' do
    User.create!(login: 'john', firstname: 'John', lastname: 'Doe', mail: 'john.doe@example.com')
    @iip.update!(csv_data: "#,Subject,assigned_to\n#{@issue.id},barfooz,john\n")
    post :result, params: build_params(update_issue: 'true').tap { |params|
                            params[:fields_map]['assigned_to'] = 'standard_field-assigned_to'
                          }
    assert_response :success
    assert !response.body.include?('Warning')
    @issue.reload
    assert_equal 'barfooz', @issue.subject
    assert_nil @issue.assigned_to
  end

  test 'should error when user type CF value is missing' do
    assigned_by_field = create_multivalue_field!('assigned_by', 'user', @issue.project)
    @tracker.custom_fields << assigned_by_field
    @issue.reload
    @issue.custom_field_values.detect { |cfv| cfv.custom_field == assigned_by_field }.value = @user
    @iip.update!(csv_data: "#,Subject,assigned_by\n#{@issue.id},barfooz,JeanDoe\n")
    @issue.update!(assigned_to: @user)
    post :result, params: build_params(update_issue: 'true').tap { |params|
                            params[:fields_map]['assigned_by'] = 'standard_field-assigned_by'
                          }
    assert_response :success
    assert response.body.include?('Warning')
    @issue.reload
    assert_equal 'foobar', @issue.subject
    assert_equal @user.name, @issue.custom_value_for(assigned_by_field).value
  end

  test 'should not error when assigned_to is missing but use_anonymous is true' do
    @iip.update!(csv_data: "#,Subject,assigned_to\n#{@issue.id},barfooz,JohnDoe\n")
    @issue.reload.update!(assigned_to: @user)
    post :result, params: build_params(update_issue: 'true', use_anonymous: 'true').tap { |params|
                            params[:fields_map]['assigned_to'] = 'standard_field-assigned_to'
                          }
    assert_response :success
    assert !response.body.include?('Warning')
    @issue.reload
    assert_equal 'barfooz', @issue.subject
    assert_nil @issue.assigned_to
  end

  test 'should match assigned_to by user display name' do
    user = User.find_by_login('jsmith')
    Member.create!(user: user, project: @project, roles: [@role])

    @iip.update!(csv_data: "#,Subject,assigned_to\n#{@issue.id},barfooz,#{user.name}\n")
    post :result, params: build_params(update_issue: 'true').tap { |params|
                            params[:fields_map]['assigned_to'] = 'standard_field-assigned_to'
                          }
    assert_response :success
    assert_not response.body.include?('Warning')
    @issue.reload
    assert_equal 'barfooz', @issue.subject
    assert_equal user, @issue.assigned_to
  end

  test 'should not error when user type CF value is missing but use_anonymous is true' do
    assigned_by_field = create_multivalue_field!('assigned_by', 'user', @issue.project)
    @tracker.custom_fields << assigned_by_field
    @issue.reload
    @issue.custom_field_values.detect { |cfv| cfv.custom_field == assigned_by_field }.value = @user
    @iip.update!(csv_data: "#,Subject,assigned_by\n#{@issue.id},barfooz,JeanDoe\n")
    @issue.update!(assigned_to: @user)
    post :result, params: build_params(update_issue: 'true', use_anonymous: 'true').tap { |params|
                            params[:fields_map]['assigned_by'] = 'custom_field-assigned_by'
                          }
    assert_response :success
    assert !response.body.include?('Warning')
    @issue.reload
    assert_equal 'barfooz', @issue.subject
    assert_equal '', @issue.custom_value_for(assigned_by_field).value
  end

  test 'should not error when user type CF value is not listed in possible values' do
    User.create!(login: 'john', firstname: 'John', lastname: 'Doe', mail: 'john.doe@example.com')
    assigned_by_field = create_multivalue_field!('assigned_by', 'user', @issue.project)
    @tracker.custom_fields << assigned_by_field
    @issue.reload
    @issue.custom_field_values.detect { |cfv| cfv.custom_field == assigned_by_field }.value = @user
    @iip.update!(csv_data: "#,Subject,assigned_by\n#{@issue.id},barfooz,john\n")
    @issue.update!(assigned_to: @user)
    post :result, params: build_params(update_issue: 'true', use_anonymous: 'true').tap { |params|
                            params[:fields_map]['assigned_by'] = 'custom_field-assigned_by'
                          }
    assert_response :success
    assert !response.body.include?('Warning')
    @issue.reload
    assert_equal 'barfooz', @issue.subject
    assert_equal '', @issue.custom_value_for(assigned_by_field).value
  end

  test 'should reset pk sequence' do
    return unless ActiveRecord::Base.connection.respond_to?(:set_pk_sequence!)
    return unless ActiveRecord::Base.connection.respond_to?(:reset_pk_sequence!)

    ActiveRecord::Base.connection.set_pk_sequence!('issues', 4422)

    @iip.update!(csv_data: "#,Subject,Tracker,Priority\n4423,test,Defect,Critical\n")
    post :result, params: build_params(use_issue_id: '1')
    assert_response :success
    assert !response.body.include?('Warning')

    issue = Issue.new
    issue.project = @project
    issue.subject = 'foobar'
    issue.priority = IssuePriority.find_by!(name: 'Critical')
    issue.tracker = @project.trackers.first
    issue.author = @user
    issue.status = IssueStatus.find_by!(name: 'New')
    issue.save!
  end

  test "should NOT change an open issue's parent to an closed issue" do
    closed_status = IssueStatus.find_or_create_by!(name: 'Closed', is_closed: true)
    parent = create_issue!(@project, @user, status: closed_status)
    @iip.update!(csv_data: "#,Parent\n#{@issue.id},#{parent.id}\n")
    post :result, params: build_params(update_issue: 'true', use_issue_id: '1')
    assert_response :success
    assert response.body.include?('Error')
    assert_nil @issue.reload.parent
  end

  test 'should NOT close an issue having open children' do
    @child = create_issue!(@project, @user, parent_id: @issue.id)
    assert @issue.children.include?(@child)
    assert !@issue.status.is_closed?
    assert !@child.status.is_closed?
    IssueStatus.find_or_create_by!(name: 'Closed', is_closed: true)
    @iip.update!(csv_data: "#,Status\n#{@issue.id},Closed\n")
    post :result, params: build_params(update_issue: 'true', use_issue_id: '1')
    assert_response :success
    assert response.body.include?('Error')
    assert !@issue.reload.status.is_closed?
  end

  test 'should NOT reopen an issue having closed parent' do
    closed_status = IssueStatus.find_or_create_by!(name: 'Closed', is_closed: true)
    new_issue = create_issue!(@project, @user, status: closed_status)
    @issue.reload.update!(status: closed_status, parent_id: new_issue.id)
    @iip.update!(csv_data: "#,Status\n#{@issue.id},New\n")
    post :result, params: build_params(update_issue: 'true', use_issue_id: '1')
    assert_response :success
    assert response.body.include?('Error')
    assert @issue.reload.status.is_closed?
  end

  test 'should handle date custom field on create' do
    start_date_field = create_date_custom_field!('StartDate', @project)
    due_date_field = create_date_custom_field!('DueDate', @project)
    @tracker.custom_fields << start_date_field
    @tracker.custom_fields << due_date_field
    Issue.delete_all
    @iip.update!(csv_data: "#,Subject,Tracker,Status,Priority,StartDate,DueDate\n1,Task with dates,Defect,New,Critical,2023-05-15,2023-06-30\n")
    post :result, params: build_params.tap { |params|
      params[:fields_map]['StartDate'] = 'custom_field-StartDate'
      params[:fields_map]['DueDate'] = 'custom_field-DueDate'
    }
    assert_response :success
    assert !response.body.include?('Warning')
    assert_equal 1, Issue.count
    issue = Issue.first
    assert_equal 'Task with dates', issue.subject
    assert_equal '2023-05-15', issue.custom_value_for(start_date_field).value
    assert_equal '2023-06-30', issue.custom_value_for(due_date_field).value
  end

  test 'should handle date custom field on update' do
    start_date_field = create_date_custom_field!('StartDate', @project)
    @tracker.custom_fields << start_date_field
    @issue.reload
    @issue.custom_field_values.detect { |cfv| cfv.custom_field == start_date_field }.value = '2023-01-01'
    @issue.save!
    @iip.update!(csv_data: "#,Subject,StartDate\n#{@issue.id},Updated task,2023-12-25\n")
    post :result, params: build_params(update_issue: 'true').tap { |params|
      params[:fields_map]['StartDate'] = 'custom_field-StartDate'
    }
    assert_response :success
    assert !response.body.include?('Warning')
    @issue.reload
    assert_equal 'Updated task', @issue.subject
    assert_equal '2023-12-25', @issue.custom_value_for(start_date_field).value
  end

  test 'should handle blank date custom field' do
    start_date_field = create_date_custom_field!('StartDate', @project)
    @tracker.custom_fields << start_date_field
    Issue.delete_all
    @iip.update!(csv_data: "#,Subject,Tracker,Status,Priority,StartDate\n1,Task with blank date,Defect,New,Critical,\n")
    post :result, params: build_params(clear_empty_cells: '1').tap { |params|
      params[:fields_map]['StartDate'] = 'custom_field-StartDate'
    }
    assert_response :success
    assert !response.body.include?('Warning')
    assert_equal 1, Issue.count
    issue = Issue.first
    assert_equal 'Task with blank date', issue.subject
    # Blank date values are stored as empty strings, not nil
    assert_equal '', issue.custom_value_for(start_date_field).value
  end

  test 'should handle invalid date custom field value' do
    invalid_date_field = create_date_custom_field!('InvalidDate', @project)
    @tracker.custom_fields << invalid_date_field
    Issue.delete_all
    @iip.update!(csv_data: "#,Subject,Tracker,Status,Priority,InvalidDate\n1,Task with invalid date,Defect,New,Critical,not-a-date\n")
    post :result, params: build_params.tap { |params|
      params[:fields_map]['InvalidDate'] = 'custom_field-InvalidDate'
    }
    assert_response :success
    assert response.body.include?('Warning')
    assert_equal 0, Issue.count
  end

  test 'should handle start_date with different format than setting' do
    Issue.delete_all
    with_settings :date_format => '%Y-%m-%d' do
      @iip.update!(csv_data: "#,Subject,Tracker,Status,Priority,Start date\n1,Task with different date format,Defect,New,Critical,15/05/2023\n")
      post :result, params: build_params.tap { |params|
        params[:fields_map]['Start date'] = 'standard_field-start_date'
      }
      assert_response :success
      assert !response.body.include?('Warning')
      assert_equal 1, Issue.count
      issue = Issue.first
      assert_equal 'Task with different date format', issue.subject
      assert_equal Date.new(2023, 5, 15), issue.start_date
    end
  end

  test 'should redirect with error when encoding does not match file' do
    # CSV including Shift-JIS bytes (not UTF-8)
    sjis_csv = "id,件名\n1,テスト件名\n".encode('Shift_JIS')

    file = Tempfile.new(['test', '.csv'])
    file.binmode
    file.write(sjis_csv)
    file.rewind

    post :match, params: {
      project_id: @project.identifier,
      file: Rack::Test::UploadedFile.new(file.path, 'text/csv'),
      wrapper: '"',
      splitter: ',',
      encoding: 'U'  # Incorrectly set to UTF-8
    }

    assert_redirected_to project_importer_path(project_id: @project.identifier)
    assert flash[:error].present?, 'encoding mismatch error should be shown'
    assert flash[:error].encoding == Encoding::UTF_8, 'flash must be UTF-8'
  ensure
    file.close
    file.unlink
  end

  test 'should redirect with error when EUC-JP file is uploaded with UTF-8 encoding' do
    # Regression test: force_encoding('UTF-8').encode('UTF-8') was a no-op in Ruby
    # (same-encoding optimization), so EUC-JP bytes were never validated.
    euc_csv = "id,件名\n1,テスト件名\n".encode('EUC-JP')

    file = Tempfile.new(['test', '.csv'])
    file.binmode
    file.write(euc_csv)
    file.rewind

    post :match, params: {
      project_id: @project.identifier,
      file: Rack::Test::UploadedFile.new(file.path, 'text/csv'),
      wrapper: '"',
      splitter: ',',
      encoding: 'U'  # Incorrectly set to UTF-8
    }

    assert_redirected_to project_importer_path(project_id: @project.identifier)
    assert flash[:error].present?, 'encoding mismatch error should be shown'
    assert_equal Encoding::UTF_8, flash[:error].encoding
  ensure
    file.close
    file.unlink
  end

  test 'should proceed normally when encoding matches file' do
    utf8_csv = "#,Subject\n1,テスト件名\n"

    file = Tempfile.new(['test', '.csv'])
    file.binmode
    file.write(utf8_csv)
    file.rewind

    post :match, params: {
      project_id: @project.identifier,
      file: Rack::Test::UploadedFile.new(file.path, 'text/csv'),
      wrapper: '"',
      splitter: ',',
      encoding: 'U'
    }

    assert_response :success
    assert_nil flash[:error]
  ensure
    file.close
    file.unlink
  end

  test 'should proceed normally when EUC-JP encoding matches file' do
    euc_csv = "#,Subject\n1,テスト件名\n".encode('EUC-JP')

    file = Tempfile.new(['test', '.csv'])
    file.binmode
    file.write(euc_csv)
    file.rewind

    post :match, params: {
      project_id: @project.identifier,
      file: Rack::Test::UploadedFile.new(file.path, 'text/csv'),
      wrapper: '"',
      splitter: ',',
      encoding: 'EUC'
    }

    assert_response :success
    assert_nil flash[:error]
  ensure
    file.close
    file.unlink
  end

  test 'should proceed normally when Shift_JIS encoding matches file' do
    sjis_csv = "#,Subject\n1,テスト件名\n".encode('Shift_JIS')

    file = Tempfile.new(['test', '.csv'])
    file.binmode
    file.write(sjis_csv)
    file.rewind

    post :match, params: {
      project_id: @project.identifier,
      file: Rack::Test::UploadedFile.new(file.path, 'text/csv'),
      wrapper: '"',
      splitter: ',',
      encoding: 'S'
    }

    assert_response :success
    assert_nil flash[:error]
  ensure
    file.close
    file.unlink
  end

  test 'should redirect with error when CSV has missing header columns with non-ASCII content' do
    # The second column is empty, causing a nil header, and also includes non-ASCII characters.
    csv_content = "id,,件名\n1,,テスト\n"

    file = Tempfile.new(['test', '.csv'])
    file.binmode
    file.write(csv_content)
    file.rewind

    post :match, params: {
      project_id: @project.identifier,
      file: Rack::Test::UploadedFile.new(file.path, 'text/csv'),
      wrapper: '"',
      splitter: ',',
      encoding: 'U'
    }

    assert_redirected_to project_importer_path(project_id: @project.identifier)
    assert flash[:error].present?
    assert_equal Encoding::UTF_8, flash[:error].encoding
  ensure
    file.close
    file.unlink
  end

  test 'should use id-based search when use_issue_id is true' do
    # Create parent issue (id will be auto-generated)
    parent = create_issue!(@project, @user, subject: 'Parent Issue')

    # With use_issue_id=true, parent should be found by id
    @iip.update!(csv_data: "#,Subject,Tracker,Status,Priority,Parent\n100,Child A,Defect,New,Critical,#{parent.id}\n")
    post :result, params: build_params(use_issue_id: '1')
    assert_response :success
    assert !response.body.include?('Warning')

    child_a = Issue.find(100)
    assert_equal parent.id, child_a.parent_id
  end

  test 'should not use id-based search when use_issue_id is false' do
    # Create parent issue (id will be auto-generated)
    parent = create_issue!(@project, @user, subject: 'Parent Issue')

    # With use_issue_id=false and unique_field='#' -> 'standard_field-id'
    # Before fix: Would incorrectly use id-based search
    # After fix: Uses query filter which should fail or behave differently
    @iip.update!(csv_data: "#,Subject,Tracker,Status,Priority,Parent\n101,Child B,Defect,New,Critical,#{parent.id}\n")
    post :result, params: build_params # use_issue_id defaults to false
    assert_response :success

    # After the fix, since 'standard_field-id' is not a valid IssueQuery filter,
    # the parent lookup should fail and produce a warning or error
    child_b = Issue.find_by(subject: 'Child B')

    # The expected behavior after fix: either warning is shown, or parent is not set
    # (depending on how IssueQuery handles invalid filters)
    if child_b
      # If issue was created, parent should not be set correctly
      # because the query filter 'standard_field-id' is invalid
      assert_nil child_b.parent_id,
        'Parent should not be set when use_issue_id=false with standard_field-id as unique_attr'
    else
      # Issue creation failed, check for warning
      assert response.body.include?('Warning'),
        'Should show warning when using standard_field-id without use_issue_id=true'
    end
  end

  test 'should narrow unique value matching down with custom field scope' do
    region = create_scope_field!('Region', %w[North South])
    north = create_issue_with_scope!('same subject', region, 'North')
    south = create_issue_with_scope!('same subject', region, 'South')

    post :result, params: scope_params('same subject,South,updated by importer')
    assert_response :success

    assert_equal 'updated by importer', south.reload.description
    assert_nil north.reload.description
  end

  test 'should narrow unique value matching down with several custom field scopes' do
    region = create_scope_field!('Region', %w[North South])
    stage = create_scope_field!('Stage', %w[Design Build])

    target = create_issue_with_scope!('same subject', region, 'South')
    target.custom_field_values = { stage.id => 'Build' }
    target.save!

    other = create_issue_with_scope!('same subject', region, 'South')
    other.custom_field_values = { stage.id => 'Design' }
    other.save!

    @iip.update!(csv_data: "Subject,Region,Stage,Description\nsame subject,South,Build,updated by importer\n")
    post :result, params: {
      import_timestamp: @iip.created.strftime('%Y-%m-%d %H:%M:%S'),
      project_id: @project.id,
      unique_field: 'Subject',
      unique_scope_fields: ['custom_field-Region', 'custom_field-Stage'],
      update_issue: 'true',
      fields_map: {
        'Subject' => 'standard_field-subject',
        'Region' => 'custom_field-Region',
        'Stage' => 'custom_field-Stage',
        'Description' => 'standard_field-description'
      }
    }
    assert_response :success

    assert_equal 'updated by importer', target.reload.description
    assert_nil other.reload.description
  end

  test 'should report multiple matches without custom field scope' do
    region = create_scope_field!('Region', %w[North South])
    create_issue_with_scope!('same subject', region, 'North')
    create_issue_with_scope!('same subject', region, 'South')

    post :result, params: scope_params('same subject,South,updated by importer',
                                       unique_scope_fields: [])
    assert_response :success
    assert response.body.include?('multiple matches'),
           'Expected a multiple matches warning when no scope is used'
  end

  test 'should reject a scope custom field that is not usable as a filter' do
    region = create_scope_field!('Region', %w[North South])
    region.update!(is_filter: false)
    create_issue_with_scope!('same subject', region, 'South')

    post :result, params: scope_params('same subject,South,updated by importer')
    assert flash[:error].present?, 'Expected an error for a non-filterable scope field'
  end

  test 'should reject a scope custom field that is not mapped to a column' do
    create_scope_field!('Region', %w[North South])

    @iip.update!(csv_data: "Subject,Description\nsame subject,updated by importer\n")
    post :result, params: {
      import_timestamp: @iip.created.strftime('%Y-%m-%d %H:%M:%S'),
      project_id: @project.id,
      unique_field: 'Subject',
      unique_scope_fields: ['custom_field-Region'],
      update_issue: 'true',
      fields_map: {
        'Subject' => 'standard_field-subject',
        'Description' => 'standard_field-description'
      }
    }
    assert flash[:error].present?, 'Expected an error for an unmapped scope field'
  end

  test 'should ignore the scope when issues are matched by id' do
    region = create_scope_field!('Region', %w[North South])
    issue = create_issue_with_scope!('scoped by id', region, 'North')

    @iip.update!(csv_data: "#,Subject,Region,Description\n#{issue.id},scoped by id,South,updated by importer\n")
    post :result, params: {
      import_timestamp: @iip.created.strftime('%Y-%m-%d %H:%M:%S'),
      project_id: @project.id,
      unique_field: '#',
      unique_scope_fields: ['custom_field-Region'],
      update_issue: 'true',
      use_issue_id: '1',
      fields_map: {
        '#' => 'standard_field-id',
        'Subject' => 'standard_field-subject',
        'Region' => 'custom_field-Region',
        'Description' => 'standard_field-description'
      }
    }
    assert_response :success

    # the scope must not prevent the issue from being found by its id,
    # even though the value of the scope field differs
    assert_equal 'updated by importer', issue.reload.description
  end

  test 'should resolve CSV-internal id references through the cache only' do
    # An issue whose database id equals the internal reference used in the CSV.
    # With use_issue_id off the "#" column is a CSV-internal reference, so this
    # issue must not be picked up as the parent.
    decoy = create_issue!(@project, @user,
                          { id: 2, subject: 'Decoy Issue', tracker: @tracker })

    @iip.update!(csv_data: "#,Subject,Tracker,Status,Priority,Parent\n1,Child Issue,Defect,New,Critical,2\n2,Parent Issue,Defect,New,Critical,\n")
    post :result, params: {
      import_timestamp: @iip.created.strftime('%Y-%m-%d %H:%M:%S'),
      unique_field: '#',
      project_id: @project.id,
      fields_map: {
        '#' => 'standard_field-id',
        'Subject' => 'standard_field-subject',
        'Tracker' => 'standard_field-tracker',
        'Status' => 'standard_field-status',
        'Priority' => 'standard_field-priority',
        'Parent' => 'standard_field-parent_issue'
      }
    }
    assert_response :success

    child = Issue.find_by!(subject: 'Child Issue')
    parent = Issue.find_by!(subject: 'Parent Issue')
    assert_equal parent.id, child.parent_id
    assert_not_equal decoy.id, child.parent_id
  end

  test 'should reject a unique column mapped to a field without a query filter' do
    @iip.update!(csv_data: "Start date,Subject\n2015-01-30,barfooz\n")
    post :result, params: {
      import_timestamp: @iip.created.strftime('%Y-%m-%d %H:%M:%S'),
      project_id: @project.id,
      unique_field: 'Start date',
      update_issue: 'true',
      fields_map: {
        'Start date' => 'standard_field-start_date',
        'Subject' => 'standard_field-subject'
      }
    }
    assert flash[:error].present?,
           'Expected an error for a unique column without a query filter'
  end

  test 'should match the unique value within the tracker of the column' do
    other_tracker = create_tracker!('Feature')
    same = create_issue!(@project, @user, { subject: 'same subject', tracker: @tracker })
    other = create_issue!(@project, @user, { subject: 'same subject', tracker: other_tracker })

    post :result, params: tracker_scope_params("same subject,#{@tracker.name},updated by importer")
    assert_response :success

    assert_equal 'updated by importer', same.reload.description
    assert_nil other.reload.description
  end

  test 'should fall back to the default tracker when the tracker column is not mapped' do
    other_tracker = create_tracker!('Feature')
    same = create_issue!(@project, @user, { subject: 'same subject', tracker: @tracker })
    other = create_issue!(@project, @user, { subject: 'same subject', tracker: other_tracker })

    @iip.update!(csv_data: "Subject,Description\nsame subject,updated by importer\n")
    post :result, params: {
      import_timestamp: @iip.created.strftime('%Y-%m-%d %H:%M:%S'),
      project_id: @project.id,
      unique_field: 'Subject',
      unique_scope_tracker: '1',
      default_tracker: @tracker.id.to_s,
      update_issue: 'true',
      fields_map: {
        'Subject' => 'standard_field-subject',
        'Description' => 'standard_field-description'
      }
    }
    assert_response :success

    assert_equal 'updated by importer', same.reload.description
    assert_nil other.reload.description
  end

  test 'should report multiple matches when the tracker restriction is off' do
    other_tracker = create_tracker!('Feature')
    create_issue!(@project, @user, { subject: 'same subject', tracker: @tracker })
    create_issue!(@project, @user, { subject: 'same subject', tracker: other_tracker })

    post :result, params: tracker_scope_params("same subject,#{@tracker.name},updated by importer",
                                               unique_scope_tracker: nil)
    assert_response :success
    assert response.body.include?('multiple matches'),
           'Expected a multiple matches warning without the tracker restriction'
  end

  test 'should allow changing the tracker of an issue when the restriction is off' do
    other_tracker = create_tracker!('Feature')
    issue = create_issue!(@project, @user, { subject: 'moved subject', tracker: @tracker })

    post :result, params: tracker_scope_params("moved subject,#{other_tracker.name},updated by importer",
                                               unique_scope_tracker: nil)
    assert_response :success

    issue.reload
    assert_equal other_tracker.id, issue.tracker_id
    assert_equal 'updated by importer', issue.description
  end

  test 'should ignore the tracker restriction when issues are matched by id' do
    other_tracker = create_tracker!('Feature')
    issue = create_issue!(@project, @user, { subject: 'by id', tracker: @tracker })

    @iip.update!(csv_data: "#,Subject,Tracker,Description\n#{issue.id},by id,#{other_tracker.name},updated by importer\n")
    post :result, params: {
      import_timestamp: @iip.created.strftime('%Y-%m-%d %H:%M:%S'),
      project_id: @project.id,
      unique_field: '#',
      unique_scope_tracker: '1',
      update_issue: 'true',
      use_issue_id: '1',
      fields_map: {
        '#' => 'standard_field-id',
        'Subject' => 'standard_field-subject',
        'Tracker' => 'standard_field-tracker',
        'Description' => 'standard_field-description'
      }
    }
    assert_response :success

    # the tracker of the row differs from the current one, the issue must
    # still be found by its id
    assert_equal 'updated by importer', issue.reload.description
  end

  test 'should require a column mapped to the id when importing by ids' do
    @iip.update!(csv_data: "Subject,Description\nno id here,text\n")
    post :result, params: {
      import_timestamp: @iip.created.strftime('%Y-%m-%d %H:%M:%S'),
      project_id: @project.id,
      unique_field: 'Subject',
      use_issue_id: '1',
      fields_map: {
        'Subject' => 'standard_field-subject',
        'Description' => 'standard_field-description'
      }
    }
    assert flash[:error].present?, 'Expected an error for the missing id mapping'
  end

  test 'should import by ids without the unique column parameter' do
    # the drop-down is disabled in the form, so the parameter never arrives
    @iip.update!(csv_data: "#,Subject,Tracker,Status,Priority\n4711,created by id,Defect,New,Critical\n")
    post :result, params: {
      import_timestamp: @iip.created.strftime('%Y-%m-%d %H:%M:%S'),
      project_id: @project.id,
      use_issue_id: '1',
      fields_map: {
        '#' => 'standard_field-id',
        'Subject' => 'standard_field-subject',
        'Tracker' => 'standard_field-tracker',
        'Status' => 'standard_field-status',
        'Priority' => 'standard_field-priority'
      }
    }
    assert_response :success
    assert_nil flash[:error]
    assert_equal 'created by id', Issue.find(4711).subject
  end

  test 'should ignore the selected unique column when importing by ids' do
    issue = create_issue!(@project, @user, { subject: 'original subject', tracker: @tracker })

    # the column left over from before the option was turned on does not match
    # anything: the issue has to be found by its id nevertheless
    @iip.update!(csv_data: "#,Subject,Description\n#{issue.id},renamed subject,updated by importer\n")
    post :result, params: {
      import_timestamp: @iip.created.strftime('%Y-%m-%d %H:%M:%S'),
      project_id: @project.id,
      unique_field: 'Subject',
      update_issue: 'true',
      use_issue_id: '1',
      fields_map: {
        '#' => 'standard_field-id',
        'Subject' => 'standard_field-subject',
        'Description' => 'standard_field-description'
      }
    }
    assert_response :success

    issue.reload
    assert_equal 'renamed subject', issue.subject
    assert_equal 'updated by importer', issue.description
  end

  test 'should ignore the identifier extraction when importing by ids' do
    issue = create_issue!(@project, @user, { subject: 'plain subject', tracker: @tracker })

    # there is no separator in the subject, so the extraction would yield
    # nothing at all if it were applied
    @iip.update!(csv_data: "#,Subject,Description\n#{issue.id},plain subject,updated by importer\n")
    post :result, params: {
      import_timestamp: @iip.created.strftime('%Y-%m-%d %H:%M:%S'),
      project_id: @project.id,
      unique_field: 'Subject',
      update_issue: 'true',
      use_issue_id: '1',
      extract_unique_value: '1',
      unique_value_separator: '|',
      fields_map: {
        '#' => 'standard_field-id',
        'Subject' => 'standard_field-subject',
        'Description' => 'standard_field-description'
      }
    }
    assert_response :success
    assert !response.body.include?('Warning')
    assert_equal 'updated by importer', issue.reload.description
  end

  test 'should match issues by the identifier extracted from the subject' do
    issue = create_issue!(@project, @user,
                          { subject: 'Old text | ABC-123', tracker: @tracker })

    post :result, params: extraction_params('Renamed text | ABC-123,updated by importer')
    assert_response :success

    issue.reload
    assert_equal 'Renamed text | ABC-123', issue.subject
    assert_equal 'updated by importer', issue.description
  end

  test 'should not match issues by the text part when the identifier is extracted' do
    issue = create_issue!(@project, @user,
                          { subject: 'Same text | ABC-123', tracker: @tracker })

    post :result, params: extraction_params('Same text | ZZZ-999,updated by importer')
    assert_response :success

    assert_nil issue.reload.description
  end

  test 'should extract the identifier from the first part of the subject' do
    issue = create_issue!(@project, @user,
                          { subject: 'ABC-123 | Old text', tracker: @tracker })

    post :result, params: extraction_params('ABC-123 | Renamed text,updated by importer',
                                            unique_value_part: 'first')
    assert_response :success

    assert_equal 'updated by importer', issue.reload.description
  end

  test 'should support a custom separator' do
    issue = create_issue!(@project, @user,
                          { subject: 'Old text :: ABC-123', tracker: @tracker })

    post :result, params: extraction_params('Renamed text :: ABC-123,updated by importer',
                                            unique_value_separator: '::')
    assert_response :success

    assert_equal 'updated by importer', issue.reload.description
  end

  test 'should skip rows without the separator' do
    issue = create_issue!(@project, @user,
                          { subject: 'No separator here', tracker: @tracker })

    post :result, params: extraction_params('No separator here,updated by importer')
    assert_response :success
    assert_nil issue.reload.description
  end

  test 'should fall back to the whole value when the separator is not found' do
    issue = create_issue!(@project, @user,
                          { subject: 'No separator here', tracker: @tracker })

    post :result, params: extraction_params('No separator here,updated by importer',
                                            unique_value_keep_whole: '1')
    assert_response :success
    assert_equal 'updated by importer', issue.reload.description
  end

  test 'should narrow the extracted identifier matching down with a custom field scope' do
    region = create_scope_field!('Region', %w[North South])
    north = create_issue_with_scope!('North text | ABC-123', region, 'North')
    south = create_issue_with_scope!('South text | ABC-123', region, 'South')

    @iip.update!(csv_data: "Subject,Region,Description\nRenamed | ABC-123,South,updated by importer\n")
    post :result, params: {
      import_timestamp: @iip.created.strftime('%Y-%m-%d %H:%M:%S'),
      project_id: @project.id,
      unique_field: 'Subject',
      unique_scope_fields: ['custom_field-Region'],
      update_issue: 'true',
      extract_unique_value: '1',
      unique_value_separator: '|',
      fields_map: {
        'Subject' => 'standard_field-subject',
        'Region' => 'custom_field-Region',
        'Description' => 'standard_field-description'
      }
    }
    assert_response :success

    assert_equal 'updated by importer', south.reload.description
    assert_nil north.reload.description
  end

  test 'should reject the extraction from a non-text unique column' do
    @iip.update!(csv_data: "Tracker,Description\nDefect | ABC-123,updated by importer\n")
    post :result, params: {
      import_timestamp: @iip.created.strftime('%Y-%m-%d %H:%M:%S'),
      project_id: @project.id,
      unique_field: 'Tracker',
      update_issue: 'true',
      extract_unique_value: '1',
      fields_map: {
        'Tracker' => 'standard_field-tracker',
        'Description' => 'standard_field-description'
      }
    }
    assert flash[:error].present?, 'Expected an error for a non-text unique column'
  end

  test 'should match the extracted identifier within the tracker of the row' do
    other_tracker = create_tracker!('Feature')
    same = create_issue!(@project, @user,
                         { subject: 'One text | ABC-123', tracker: @tracker })
    other = create_issue!(@project, @user,
                          { subject: 'Other text | ABC-123', tracker: other_tracker })

    @iip.update!(csv_data: "Subject,Tracker,Description\nRenamed | ABC-123,#{@tracker.name},updated by importer\n")
    post :result, params: {
      import_timestamp: @iip.created.strftime('%Y-%m-%d %H:%M:%S'),
      project_id: @project.id,
      unique_field: 'Subject',
      unique_scope_tracker: '1',
      update_issue: 'true',
      extract_unique_value: '1',
      unique_value_separator: '|',
      fields_map: {
        'Subject' => 'standard_field-subject',
        'Tracker' => 'standard_field-tracker',
        'Description' => 'standard_field-description'
      }
    }
    assert_response :success

    assert_equal 'updated by importer', same.reload.description
    assert_nil other.reload.description
  end

  test 'should list the conflicting issues when the identifier is not unique' do
    create_issue!(@project, @user, { subject: 'One text | ABC-123', tracker: @tracker })
    create_issue!(@project, @user, { subject: 'Other text | ABC-123', tracker: @tracker })

    post :result, params: extraction_params('Renamed | ABC-123,updated by importer')
    assert_response :success

    assert response.body.include?('multiple matches'),
           'Expected a multiple matches warning'
    assert response.body.match?(/#\d+, #\d+/),
           'Expected the ids of the conflicting issues in the warning'
  end

  test 'should ignore a mark following the identifier' do
    issue = create_issue!(@project, @user,
                          { subject: 'Old text | ABC-123 [ДУБЛЬ]', tracker: @tracker })

    post :result, params: extraction_params('Renamed text | ABC-123,updated by importer')
    assert_response :success

    assert_equal 'updated by importer', issue.reload.description
  end

  test 'should ignore a mark coming from the CSV as well' do
    issue = create_issue!(@project, @user,
                          { subject: 'Old text | ABC-123', tracker: @tracker })

    post :result, params: extraction_params('Renamed text | ABC-123 [ДУБЛЬ],updated by importer')
    assert_response :success

    issue.reload
    assert_equal 'Renamed text | ABC-123 [ДУБЛЬ]', issue.subject
    assert_equal 'updated by importer', issue.description
  end

  test 'should ignore several marks following the identifier' do
    issue = create_issue!(@project, @user,
                          { subject: 'Old text | ABC-123 [ДУБЛЬ] [АРХИВ]', tracker: @tracker })

    post :result, params: extraction_params('Renamed text | ABC-123 [АРХИВ],updated by importer')
    assert_response :success

    assert_equal 'updated by importer', issue.reload.description
  end

  test 'should ignore a mark when the identifier is the first part' do
    issue = create_issue!(@project, @user,
                          { subject: 'ABC-123 [ДУБЛЬ] | Old text', tracker: @tracker })

    post :result, params: extraction_params('ABC-123 | Renamed text,updated by importer',
                                            unique_value_part: 'first')
    assert_response :success

    assert_equal 'updated by importer', issue.reload.description
  end

  test 'should keep brackets that are not separated from the identifier' do
    with_space = create_issue!(@project, @user,
                               { subject: 'One text | ABC-123 [1]', tracker: @tracker })
    without_space = create_issue!(@project, @user,
                                  { subject: 'Other text | ABC-123[1]', tracker: @tracker })

    post :result, params: extraction_params('Renamed | ABC-123[1],updated by importer')
    assert_response :success

    assert_equal 'updated by importer', without_space.reload.description
    assert_nil with_space.reload.description
  end

  test 'should skip a value consisting of a mark only' do
    issue = create_issue!(@project, @user,
                          { subject: 'Old text | [ДУБЛЬ]', tracker: @tracker })

    post :result, params: extraction_params('Renamed text | [ДУБЛЬ],updated by importer')
    assert_response :success

    assert_nil issue.reload.description
  end

  test 'should accept a bare identifier in the parent column' do
    parent = create_issue!(@project, @user,
                           { subject: 'Parent text | 000.0000.000', tracker: @tracker })

    post :result, params: extraction_reference_params(
      "Child text | 000.0000.001,000.0000.000\n"
    )
    assert_response :success

    child = Issue.find_by!(subject: 'Child text | 000.0000.001')
    assert_equal parent.id, child.parent_id
    assert_not response.body.include?('could be extracted')
  end

  test 'should accept a full pair in the parent column' do
    parent = create_issue!(@project, @user,
                           { subject: 'Parent text | 000.0000.000', tracker: @tracker })

    post :result, params: extraction_reference_params(
      "Child text | 000.0000.001,Any other text | 000.0000.000\n"
    )
    assert_response :success

    child = Issue.find_by!(subject: 'Child text | 000.0000.001')
    assert_equal parent.id, child.parent_id
  end

  test 'should accept a bare identifier with a mark in the parent column' do
    parent = create_issue!(@project, @user,
                           { subject: 'Parent text | 000.0000.000', tracker: @tracker })

    post :result, params: extraction_reference_params(
      "Child text | 000.0000.001,000.0000.000 [ДУБЛЬ]\n"
    )
    assert_response :success

    child = Issue.find_by!(subject: 'Child text | 000.0000.001')
    assert_equal parent.id, child.parent_id
  end

  test 'should resolve a bare identifier referring to a later row' do
    post :result, params: extraction_reference_params(
      "Child text | 000.0000.001,000.0000.000\nParent text | 000.0000.000,\n"
    )
    assert_response :success

    child = Issue.find_by!(subject: 'Child text | 000.0000.001')
    parent = Issue.find_by!(subject: 'Parent text | 000.0000.000')
    assert_equal parent.id, child.parent_id
  end

  test 'should reject a mapping of several columns to the same field' do
    @iip.update!(csv_data: "Subject,Parent,Old parent\nfoo,,0\n")
    post :result, params: {
      import_timestamp: @iip.created.strftime('%Y-%m-%d %H:%M:%S'),
      project_id: @project.id,
      unique_field: 'Subject',
      update_issue: 'true',
      fields_map: {
        'Subject' => 'standard_field-subject',
        'Parent' => 'standard_field-parent_issue',
        'Old parent' => 'standard_field-parent_issue'
      }
    }
    assert flash[:error].present?, 'Expected an error for a duplicate mapping'
    assert flash[:error].include?('Parent'), 'Expected the columns in the message'
  end

  test 'should allow several unmapped columns' do
    @iip.update!(csv_data: "Subject,Note,Comment\nfoo,a,b\n")
    post :result, params: {
      import_timestamp: @iip.created.strftime('%Y-%m-%d %H:%M:%S'),
      project_id: @project.id,
      unique_field: 'Subject',
      update_issue: 'true',
      fields_map: {
        'Subject' => 'standard_field-subject',
        'Note' => '',
        'Comment' => ''
      }
    }
    assert_response :success
    assert_nil flash[:error]
  end

  test 'should name the column in the unresolved reference warning' do
    post :result, params: extraction_reference_params(
      "Child text | 000.0000.001,000.0000.999\n"
    )
    assert_response :success

    assert response.body.include?('never resolved'), 'Expected an unresolved warning'
    assert response.body.include?("of the column 'Parent'"),
           'Expected the column name in the unresolved warning'
  end

  test 'should name the scope in the unresolved reference warning' do
    @iip.update!(csv_data: "Subject,Tracker,Parent\n" \
                           "Child text | 000.0000.001,#{@tracker.name},000.0000.999\n")
    post :result, params: {
      import_timestamp: @iip.created.strftime('%Y-%m-%d %H:%M:%S'),
      project_id: @project.id,
      unique_field: 'Subject',
      unique_scope_tracker: '1',
      update_issue: 'true',
      extract_unique_value: '1',
      unique_value_separator: '|',
      fields_map: {
        'Subject' => 'standard_field-subject',
        'Tracker' => 'standard_field-tracker',
        'Parent' => 'standard_field-parent_issue'
      }
    }
    assert_response :success

    assert response.body.include?('never resolved'), 'Expected an unresolved warning'
    assert response.body.include?(@tracker.name),
           'Expected the scope in the unresolved warning'
  end

  test 'should record the issues the import has updated' do
    @iip.update!(csv_data: "#,Subject\n#{@issue.id},updated by the import\n")
    post :result, params: build_params(update_issue: 'true', use_issue_id: '1')
    assert_response :success

    assert_equal [], assigns(:created_issue_ids)
    assert_equal [@issue.id], assigns(:updated_issue_ids)
    assert response.body.include?("issue_id=#{@issue.id}"),
           'Expected a link opening the updated issue in the issue list'
  end

  test 'should record the issues the import has created' do
    post :result, params: creation_params("first new issue\nsecond new issue\n")
    assert_response :success

    created = assigns(:created_issue_ids)
    assert_equal ['first new issue', 'second new issue'],
                 Issue.where(id: created).order(:id).pluck(:subject)
    assert_equal [], assigns(:updated_issue_ids)
    assert response.body.include?("issue_id=#{created.join('%2C')}") ||
           response.body.include?("issue_id=#{created.join(',')}"),
           'Expected a link opening the created issues in the issue list'
  end

  test 'should link a long list of imported issues by the range it spans' do
    ids = (1..(ImporterController::RESULT_ISSUE_LIST_LINK_LIMIT + 1)).to_a

    link = @controller.view_context.imported_issues_link(ids)
    assert link.include?('op%5Bissue_id%5D=%3E%3C'),
           'Expected the between operator for a list too long for the address'
    assert link.include?(ids.min.to_s) && link.include?(ids.max.to_s)
  end

  test 'should report the progress of the import' do
    post :result, params: creation_params("progress row\n")
    assert_response :success

    get :progress, params: { project_id: @project.id,
                             import_timestamp: @import_timestamp }
    assert_response :success

    status = JSON.parse(response.body)
    assert_equal ImportInProgress::STAGE_FINISHED, status['stage']
    assert status['finished']
    assert_equal 100, status['percent']
    assert_equal 1, status['total_rows']
    assert_equal 1, status['processed_rows']
    assert_equal 1, status['created_count']
    assert_equal 0, status['updated_count']
  end

  test 'should keep the row of the import as finished without its payload' do
    post :result, params: creation_params("a row of a finished import\n")
    assert_response :success

    iip = ImportInProgress.find_by_user_id(@user.id)
    assert iip, 'Expected the row of the import to outlive it'
    assert iip.finished?
    assert_equal ImportInProgress::STAGE_FINISHED, iip.stage
    assert iip.csv_data.blank?, 'Expected the file to be dropped'

    # the same form sent twice must not import the file a second time
    assert_no_difference 'Issue.count' do
      post :result, params: { import_timestamp: @import_timestamp,
                              project_id: @project.id }
    end
    assert_equal I18n.t(:error_import_already_done), flash[:error]
  end

  test 'should keep the file of an import that failed' do
    post :result, params: creation_params("a row of a failed import\n")
                  .merge(import_timestamp: '1999-01-01 00:00:00')
    assert_response :success
    assert_equal I18n.t(:error_import_superseded), flash[:error]

    iip = ImportInProgress.find_by_user_id(@user.id)
    assert iip.csv_data.present?, 'Expected the file to be kept for a retry'
  end

  test 'should report an unknown progress when no import was started' do
    ImportInProgress.delete_all

    get :progress, params: { project_id: @project.id }
    assert_response :success
    assert_equal ImportInProgress::STAGE_UNKNOWN,
                 JSON.parse(response.body)['stage']
  end

  test 'should report an unknown progress for another import of the user' do
    post :result, params: creation_params("a row of the first import\n")
    assert_response :success

    get :progress, params: { project_id: @project.id,
                             import_timestamp: '1970-01-01 00:00:00' }
    assert_response :success
    assert_equal ImportInProgress::STAGE_UNKNOWN,
                 JSON.parse(response.body)['stage']
  end

  test 'should import when the progress cannot be reported' do
    ImportInProgress.any_instance.stubs(:report!)
                    .raises(ActiveRecord::StatementInvalid.new('no such column'))

    post :result, params: creation_params("a row imported without progress\n")
    assert_response :success
    assert Issue.find_by(subject: 'a row imported without progress'),
           'Expected the import to run without the progress reporting'
  end

  # --- The combined mode: update what is there, create the rest -------------

  test 'should create the issue a row finds no match for' do
    post :result, params: subject_params("no such issue,Critical,created by the import\n")
    assert_response :success

    issue = Issue.find_by(subject: 'no such issue')
    assert issue, 'Expected the row without a match to create an issue'
    assert_equal 'created by the import', issue.description
    assert_equal [issue.id], assigns(:created_issue_ids)
    assert_equal 0, assigns(:failed_count)
  end

  test 'should update the issue a row matches instead of creating one' do
    issue = create_issue!(@project, @user, { subject: 'already there', tracker: @tracker })

    assert_no_difference 'Issue.count' do
      post :result, params: subject_params("already there,Critical,updated by the import\n")
    end
    assert_response :success

    assert_equal 'updated by the import', issue.reload.description
    assert_equal [issue.id], assigns(:updated_issue_ids)
  end

  test 'should skip a row without a match when non-existant issues are ignored' do
    assert_no_difference 'Issue.count' do
      post :result, params: subject_params("no such issue,Critical,created by the import\n",
                                           ignore_non_exist: '1')
    end
    assert_response :success

    assert_equal 1, assigns(:skip_count)
    assert_equal 0, assigns(:failed_count)
  end

  test 'should import as new issues when no column carries the unique values' do
    post :result, params: subject_params("nothing to match by,Critical,\n").except(:unique_field)
    assert_response :success

    assert_nil flash[:error]
    assert Issue.find_by(subject: 'nothing to match by'),
           'Expected the file to be imported as new issues'
    assert response.body.include?('imported as new issues'),
           'Expected the result to say the update was switched off'
  end

  # --- Only the issues a row changes are written ----------------------------

  test 'should leave an issue a row changes nothing on untouched' do
    updated_on = @issue.reload.updated_on

    post :result, params: id_params("#{@issue.id},foobar,Critical\n")
    assert_response :success

    assert_equal 1, assigns(:unchanged_count)
    assert_equal [], assigns(:updated_issue_ids)
    assert_equal updated_on.to_i, @issue.reload.updated_on.to_i
    assert_equal 0, @issue.journals.count,
                 'Expected no journal for an issue nothing was written to'
  end

  test 'should write the issues a row does change' do
    post :result, params: id_params("#{@issue.id},changed by the import,Critical\n")
    assert_response :success

    assert_equal 0, assigns(:unchanged_count)
    assert_equal [@issue.id], assigns(:updated_issue_ids)
    assert_equal 'changed by the import', @issue.reload.subject
  end

  test 'should count the unchanged rows next to the changed ones' do
    other = create_issue!(@project, @user, { subject: 'second', tracker: @tracker })

    post :result, params: id_params("#{@issue.id},foobar,Critical\n" \
                                    "#{other.id},renamed,Critical\n")
    assert_response :success

    assert_equal 1, assigns(:unchanged_count)
    assert_equal [other.id], assigns(:updated_issue_ids)
    assert response.body.include?('Unchanged: 1')
  end

  # --- The column the rows are matched by -----------------------------------

  test 'should refuse a file the matching column is not in' do
    params = id_params("#{@issue.id},foobar,Critical,\n")
             .merge(unique_field: 'Identifier')

    assert_no_difference 'Issue.count' do
      post :result, params: params
    end
    assert_response :success

    assert flash[:error].present?
    assert flash[:error].include?('Identifier')
  end

  test 'should refuse an import by ids whose id column is not in the file' do
    params = id_params("#{@issue.id},foobar,Critical,\n")
    params[:fields_map] = params[:fields_map].except('#')
                                             .merge('Ticket' => 'standard_field-id')

    assert_no_difference 'Issue.count' do
      post :result, params: params
    end
    assert_response :success

    assert flash[:error].present?
    assert flash[:error].include?('Ticket')
  end

  test 'should import a file whose columns are all in place' do
    post :result, params: id_params("#{@issue.id},renamed,Critical,\n")
    assert_response :success

    assert_nil flash[:error]
    assert_equal 'renamed', @issue.reload.subject
  end

  # --- Empty cells and the clearing marker ----------------------------------

  test 'should keep the stored value when a mapped cell is empty' do
    @issue.update!(description: 'written by hand')

    post :result, params: id_params("#{@issue.id},foobar,Critical,\n")
    assert_response :success

    assert_equal 'written by hand', @issue.reload.description
    assert_equal 1, assigns(:unchanged_count),
                 'Expected a file saying nothing new to change nothing'
  end

  test 'should empty the field when a mapped cell is empty and asked to' do
    @issue.update!(description: 'written by hand')

    post :result, params: id_params("#{@issue.id},foobar,Critical,\n",
                                    clear_empty_cells: '1')
    assert_response :success

    assert_nil @issue.reload.description
    assert_equal [@issue.id], assigns(:updated_issue_ids)
  end

  test 'should empty the field the clearing marker is put in' do
    @issue.update!(description: 'written by hand')

    post :result, params: id_params("#{@issue.id},foobar,Critical,[CLEAR]\n")
    assert_response :success

    assert_nil @issue.reload.description
    assert_equal [@issue.id], assigns(:updated_issue_ids)
  end

  test 'should never write the clearing marker itself' do
    @issue.update!(description: 'written by hand')

    post :result, params: id_params("#{@issue.id},foobar,Critical,[clear]\n")
    assert_response :success

    @issue.reload
    assert_nil @issue.description
    detail = @issue.journals.last.details.detect { |d| d.prop_key == 'description' }
    assert detail, 'Expected the emptying to be journalled'
    assert detail.value.blank?, 'Expected the marker to stay out of the history'
    assert_not response.body.downcase.include?('[clear]')
  end

  test 'should ignore the clearing marker in a column that cannot be emptied' do
    post :result, params: id_params("#{@issue.id},[CLEAR],Critical,\n")
    assert_response :success

    assert_equal 'foobar', @issue.reload.subject
    assert response.body.include?('cannot be emptied')
  end

  test 'should read an empty progress as no progress' do
    @issue.update!(done_ratio: 40)

    post :result, params: id_params("#{@issue.id},foobar,Critical,[CLEAR]\n")
             .tap { |p| p[:fields_map]['Description'] = 'standard_field-done_ratio' }
    assert_response :success

    assert_equal 0, @issue.reload.done_ratio
  end

  test 'should leave the private flag alone on a word it does not know' do
    post :result, params: id_params("#{@issue.id},foobar,Critical,maybe\n")
             .tap { |p| p[:fields_map]['Description'] = 'standard_field-is_private' }
    assert_response :success

    assert_equal false, @issue.reload.is_private
    assert response.body.include?('neither yes nor no')
  end

  # --- The deletion mode ----------------------------------------------------

  test 'should delete the issues the rows name' do
    other = create_issue!(@project, @user, { subject: 'to keep', tracker: @tracker })

    post :result, params: id_params("#{@issue.id},foobar,Critical\n", delete_issues: '1')
    assert_response :success

    assert_nil Issue.find_by(id: @issue.id)
    assert Issue.exists?(other.id), 'Expected the issues no row names to be kept'
    assert_equal [@issue.id], assigns(:deleted_issue_ids)
    assert response.body.include?('Deleted: 1')
  end

  test 'should delete the subtasks along with the issue' do
    child = create_issue!(@project, @user, { subject: 'child', parent_id: @issue.id })

    post :result, params: id_params("#{@issue.id},foobar,Critical\n", delete_issues: '1')
    assert_response :success

    assert_nil Issue.find_by(id: child.id)
    assert_equal [@issue.id, child.id].sort, assigns(:deleted_issue_ids).sort
  end

  test 'should write nothing to the issues in the deletion mode' do
    post :result, params: id_params("#{@issue.id},renamed by the import,Critical\n",
                                    delete_issues: '1', update_issue: 'true')
    assert_response :success

    assert_nil Issue.find_by(id: @issue.id)
    assert_equal [], assigns(:created_issue_ids)
    assert_equal [], assigns(:updated_issue_ids)
  end

  test 'should report a row the deletion finds no issue for' do
    post :result, params: id_params("999001,nothing,Critical\n", delete_issues: '1')
    assert_response :success

    assert_equal 1, assigns(:failed_count)
    assert response.body.include?('Could not delete issue')
  end

  test 'should skip a row the deletion finds no issue for when they are ignored' do
    post :result, params: id_params("999001,nothing,Critical\n",
                                    delete_issues: '1', ignore_non_exist: '1')
    assert_response :success

    assert_equal 1, assigns(:skip_count)
    assert_equal 0, assigns(:failed_count)
  end

  test 'should refuse the deletion without a way to match the issues' do
    params = id_params("#{@issue.id},foobar,Critical\n", delete_issues: '1')
             .except(:use_issue_id, :unique_field)

    post :result, params: params
    assert_response :success

    assert_equal I18n.t(:error_delete_requires_unique_field), flash[:error]
    assert Issue.exists?(@issue.id), 'Expected nothing to be deleted'
  end

  test 'should not delete issues without the permission to delete them' do
    @user.update!(admin: false)

    post :result, params: id_params("#{@issue.id},foobar,Critical\n", delete_issues: '1')
    assert_response :success

    assert Issue.exists?(@issue.id), 'Expected the issue to survive'
    assert_equal 1, assigns(:failed_count)
    assert response.body.include?('not allowed to delete issues')
  end

  protected

  # An import matching the issues by their own ids. The file holds the id, the
  # subject and the priority, so that a row can be made to repeat exactly what
  # the issue already carries.
  def id_params(rows, opts = {})
    crud_iip!("#,Subject,Priority,Description\n#{rows}")

    {
      import_timestamp: @iip.created.strftime('%Y-%m-%d %H:%M:%S'),
      project_id: @project.id,
      unique_field: '#',
      use_issue_id: '1',
      update_issue: 'true',
      default_tracker: @tracker.id,
      fields_map: {
        '#' => 'standard_field-id',
        'Subject' => 'standard_field-subject',
        'Priority' => 'standard_field-priority',
        'Description' => 'standard_field-description'
      }
    }.merge(opts)
  end

  # An import matching the issues by their subject, so that a row without a
  # match has an issue to create
  def subject_params(rows, opts = {})
    crud_iip!("Subject,Priority,Description\n#{rows}")

    {
      import_timestamp: @iip.created.strftime('%Y-%m-%d %H:%M:%S'),
      project_id: @project.id,
      unique_field: 'Subject',
      update_issue: 'true',
      default_tracker: @tracker.id,
      fields_map: {
        'Subject' => 'standard_field-subject',
        'Priority' => 'standard_field-priority',
        'Description' => 'standard_field-description'
      }
    }.merge(opts)
  end

  def crud_iip!(csv_data)
    @iip = ImportInProgress.find_or_initialize_by(user_id: @user.id)
    @iip.csv_data = csv_data
    @iip.created = DateTime.now
    @iip.encoding = 'UTF-8'
    @iip.col_sep = ','
    @iip.quote_char = '"'
    @iip.save!
    @iip
  end

  # An import of new issues: every line of +subjects+ becomes an issue
  def creation_params(subjects)
    @iip.update!(csv_data: "Subject,Tracker\n" +
                           subjects.lines.map { |s| "#{s.chomp},#{@tracker.name}\n" }.join)
    @import_timestamp = @iip.created.strftime('%Y-%m-%d %H:%M:%S')
    {
      import_timestamp: @import_timestamp,
      project_id: @project.id,
      fields_map: {
        'Subject' => 'standard_field-subject',
        'Tracker' => 'standard_field-tracker'
      }
    }
  end

  def extraction_reference_params(csv_rows, opts = {})
    @iip = ImportInProgress.find_or_initialize_by(user_id: @user.id)
    @iip.csv_data = "Subject,Parent\n#{csv_rows}"
    @iip.created = DateTime.now
    @iip.encoding = 'UTF-8'
    @iip.col_sep = ','
    @iip.quote_char = '"'
    @iip.save!

    {
      import_timestamp: @iip.created.strftime('%Y-%m-%d %H:%M:%S'),
      project_id: @project.id,
      unique_field: 'Subject',
      update_issue: 'true',
      extract_unique_value: '1',
      unique_value_separator: '|',
      default_tracker: @tracker.id.to_s,
      fields_map: {
        'Subject' => 'standard_field-subject',
        'Parent' => 'standard_field-parent_issue'
      }
    }.merge(opts)
  end


  def extraction_params(csv_row, opts = {})
    @iip = ImportInProgress.find_or_initialize_by(user_id: @user.id)
    @iip.csv_data = "Subject,Description\n#{csv_row}\n"
    @iip.created = DateTime.now
    @iip.encoding = 'UTF-8'
    @iip.col_sep = ','
    @iip.quote_char = '"'
    @iip.save!

    {
      import_timestamp: @iip.created.strftime('%Y-%m-%d %H:%M:%S'),
      project_id: @project.id,
      unique_field: 'Subject',
      update_issue: 'true',
      extract_unique_value: '1',
      unique_value_separator: '|',
      fields_map: {
        'Subject' => 'standard_field-subject',
        'Description' => 'standard_field-description'
      }
    }.merge(opts)
  end

  def create_tracker!(name)
    tracker = Tracker.new(name: name)
    tracker.default_status = IssueStatus.find_or_create_by!(name: 'New')
    tracker.save!
    @project.trackers << tracker
    @project.save!
    tracker
  end

  def tracker_scope_params(csv_row, opts = {})
    @iip.update!(csv_data: "Subject,Tracker,Description\n#{csv_row}\n")

    {
      import_timestamp: @iip.created.strftime('%Y-%m-%d %H:%M:%S'),
      project_id: @project.id,
      unique_field: 'Subject',
      unique_scope_tracker: '1',
      update_issue: 'true',
      fields_map: {
        'Subject' => 'standard_field-subject',
        'Tracker' => 'standard_field-tracker',
        'Description' => 'standard_field-description'
      }
    }.merge(opts).compact
  end


  def create_scope_field!(name, possible_values)
    field = IssueCustomField.new name: name,
                                 field_format: 'list',
                                 possible_values: possible_values,
                                 is_filter: true,
                                 multiple: false
    field.projects << @project
    field.save!
    @tracker.custom_fields << field
    @tracker.save!
    field
  end

  def create_issue_with_scope!(subject, field, value)
    issue = create_issue!(@project, @user, { subject: subject, tracker: @tracker })
    issue.custom_field_values = { field.id => value }
    issue.save!
    issue
  end

  def scope_params(csv_row, opts = {})
    @iip.update!(csv_data: "Subject,Region,Description\n#{csv_row}\n")

    {
      import_timestamp: @iip.created.strftime('%Y-%m-%d %H:%M:%S'),
      project_id: @project.id,
      unique_field: 'Subject',
      unique_scope_fields: ['custom_field-Region'],
      update_issue: 'true',
      fields_map: {
        'Subject' => 'standard_field-subject',
        'Region' => 'custom_field-Region',
        'Description' => 'standard_field-description'
      }
    }.merge(opts)
  end

  def build_params(opts = {})
    @iip.reload
    opts.reverse_merge(
      import_timestamp: @iip.created.strftime('%Y-%m-%d %H:%M:%S'),
      unique_field: '#',
      project_id: @project.identifier,
      fields_map: {
        '#' => 'standard_field-id',
        'Subject' => 'standard_field-subject',
        'Tags' => 'custom_field-Tags',
        'Affected versions' => 'custom_field-Affected versions',
        'Priority' => 'standard_field-priority',
        'Tracker' => 'standard_field-tracker',
        'Status' => 'standard_field-status',
        'Watchers' => 'standard_field-watchers',
        'Parent' => 'standard_field-parent_issue',
        'Area' => 'custom_field-Area'
      }
    )
  end

  def issue_has_all_these_multival_versions?(issue, version_names)
    find_version_ids(version_names).all? do |version_to_find|
      versions_for(issue).include?(version_to_find)
    end
  end

  def issue_has_none_of_these_multival_versions?(issue, version_names)
    find_version_ids(version_names).none? do |version_to_find|
      versions_for(issue).include?(version_to_find)
    end
  end

  def issue_has_none_of_these_watchers?(issue, watchers)
    watchers.none? do |watcher|
      issue.watcher_users.include?(watcher)
    end
  end

  def issue_has_all_of_these_watchers?(issue, watchers)
    watchers.all? do |watcher|
      issue.watcher_users.include?(watcher)
    end
  end

  def find_version_ids(version_names)
    version_names.map do |name|
      Version.find_by_name!(name).id.to_s
    end
  end

  def versions_for(issue)
    versions_field = CustomField.find_by_name! 'Affected versions'
    value_objs = issue.custom_values.where(custom_field_id: versions_field.id)
    values = value_objs.map(&:value)
  end

  def issue_has_all_these_multifield_vals?(issue, vals_to_find)
    vals_to_find.all? do |val_to_find|
      multifield_vals_for(issue).include?(val_to_find)
    end
  end

  def issue_has_none_of_these_multifield_vals?(issue, vals_to_find)
    vals_to_find.none? do |val_to_find|
      multifield_vals_for(issue).include?(val_to_find)
    end
  end

  def multifield_vals_for(issue)
    multival_field = CustomField.find_by_name! 'Tags'
    value_objs = issue.custom_values.where(custom_field_id: multival_field.id)
    values = value_objs.map(&:value)
  end

  def keyval_vals_for(issue)
    keyval_field = CustomField.find_by_name! 'Area'
    value_objs = issue.custom_values.where(custom_field_id: keyval_field.id)
    value_objs.map { |value_obj| keyval_field.enumerations.find(value_obj.value).name }
  end

  def create_user!(role, project)
    user = User.new admin: true,
                    login: 'bob',
                    firstname: 'Bob',
                    lastname: 'Loblaw',
                    mail: 'bob.loblaw@example.com'
    user.login = 'bob'
    sponsor = User.new admin: true,
                       firstname: 'A',
                       lastname: 'H',
                       mail: 'a@example.com'
    sponsor.login = 'alice'

    membership = user.memberships.build(project: project)
    membership.roles << role
    membership.principal = user

    membership = sponsor.memberships.build(project: project)
    membership.roles << role
    membership.principal = sponsor
    sponsor.save!
    user.pref.auto_watch_on = nil if Redmine::VERSION.to_s.to_f >= 5.1
    user.save!
    user
  end

  def create_iip_for_multivalues!(user, project)
    create_iip!('CustomFieldMultiValues', user, project)
  end

  def create_iip!(filename, user, _project)
    iip = ImportInProgress.new
    iip.user = user
    iip.csv_data = get_csv(filename)
    # iip.created = DateTime.new(2001,2,3,4,5,6,'+7')
    iip.created = DateTime.now
    iip.encoding = 'UTF-8'
    iip.col_sep = ','
    iip.quote_char = '"'
    iip.save!
    iip
  end

  def create_issue!(project, author, options = {})
    issue = Issue.new
    issue.id = options[:id]
    issue.parent_id = options[:parent_id]
    issue.project = project
    issue.subject = options[:subject] || 'foobar'
    issue.priority = IssuePriority.find_or_create_by!(name: 'Critical')
    issue.tracker = options[:tracker] || project.trackers.first
    issue.author = author
    issue.status = options[:status] || IssueStatus.find_or_create_by!(name: 'New')
    issue.start_date = author.today
    issue.save!
    issue
  end

  def create_custom_fields!(issue)
    versions_field = create_multivalue_field!('Affected versions',
                                              'version',
                                              issue.project)
    multival_field = create_multivalue_field!('Tags',
                                              'list',
                                              issue.project,
                                              %w[tag1 tag2])
    keyval_field = create_enumeration_field!('Area',
                                             issue.project,
                                             %w[Tokyo Osaka])
    issue.tracker.custom_fields << versions_field
    issue.tracker.custom_fields << multival_field
    issue.tracker.custom_fields << keyval_field
    issue.tracker.save!
  end

  def create_multivalue_field!(name, format, project, possible_vals = [])
    field = IssueCustomField.new name: name, multiple: true
    field.field_format = format
    field.projects << project
    field.possible_values = possible_vals if possible_vals
    field.save!
    field
  end

  def create_enumeration_field!(name, project, enumerations)
    field = IssueCustomField.new name: name, multiple: true, field_format: 'enumeration'
    field.projects << project
    field.save!
    enumerations.each.with_index(1) do |name, position|
      CustomFieldEnumeration.create!(name: name, custom_field_id: field.id, active: true, position: position)
    end
    field
  end

  def create_versions!(project)
    project.versions.create! name: 'Admin', status: 'open'
    project.versions.create! name: '2013-09-25', status: 'open'
  end

  def create_date_custom_field!(name, project)
    field = IssueCustomField.new name: name, multiple: false
    field.field_format = 'date'
    field.projects << project
    field.save!
    field
  end

  def get_csv(filename)
    File.read(File.expand_path("../../samples/#{filename}.csv", __FILE__))
  end
end
