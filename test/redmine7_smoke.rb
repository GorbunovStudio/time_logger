require 'minitest/autorun'
require 'action_controller/test_case'
require 'active_support/testing/time_helpers'

class TimeLoggerSmokeTest < ActionController::TestCase
  include ActiveSupport::Testing::TimeHelpers
  tests TimeLoggersController

  setup do
    raise 'Run only against upgraded local db' unless ActiveRecord::Base.connection_db_config.host == 'db'
    raise 'Slack must stay disabled' unless ENV['REDMINE_SLACK_DELIVERY_ENABLED'] == '0'
    @connection = ActiveRecord::Base.connection
    @connection.begin_transaction(joinable: false)
    @delivery_method = ActionMailer::Base.delivery_method
    @adapter = ActiveJob::Base.queue_adapter
    ActionMailer::Base.delivery_method = :test
    ActiveJob::Base.queue_adapter = :test
    @routes = Rails.application.routes
    @user = User.active.where(admin: true).first!
    @issue = Issue.joins(:project).where(projects: {status: Project::STATUS_ACTIVE}).first!
    @issue.project.enable_module!(:time_tracking)
    TimeLogger.delete_all
    Setting.plugin_time_logger = {'status_transitions' => {}, 'redirect_to_new_time_entry' => 'off'}
    sign_in(@user)
  end

  teardown do
    travel_back
    @connection.rollback_transaction if @connection
    ActionMailer::Base.delivery_method = @delivery_method
    ActiveJob::Base.queue_adapter = @adapter
    User.current = nil
    Setting.clear_cache
  end

  def test_start_pause_resume_and_stop_preserve_elapsed_time
    travel_to Time.current.change(usec: 0)
    original_count = TimeEntry.count
    post :start, params: {issue_id: @issue.id}, xhr: true
    assert_response :success
    timer = TimeLogger.find_by!(user: @user)
    assert_equal 0, timer.time_spent
    travel 125.seconds
    post :suspend, params: {id: timer.id}, xhr: true
    assert_response :success
    assert_includes response.body, 'pause_timer();'
    assert timer.reload.paused?
    assert_equal 125, timer.seconds_spent
    travel 300.seconds
    assert_equal 125, timer.reload.seconds_spent
    post :resume, params: {id: timer.id}, xhr: true
    assert_response :success
    assert_includes response.body, 'start_timer('
    travel 55.seconds
    assert_equal 180, timer.reload.seconds_spent
    post :stop, params: {id: timer.id}
    assert_redirected_to controller: 'issues', action: 'edit', id: @issue.id, time_entry: {hours: 0.05}
    refute TimeLogger.exists?(timer.id)
    assert_equal original_count, TimeEntry.count
  end

  def test_cannot_start_two_timers
    post :start, params: {issue_id: @issue.id}, xhr: true
    assert_response :success
    post :start, params: {issue_id: @issue.id}, xhr: true
    assert_response :bad_request
    assert_equal 1, TimeLogger.where(user: @user).count
  end

  def test_explicit_redirect_setting_opens_native_time_form
    Setting.plugin_time_logger = Setting.plugin_time_logger.merge('redirect_to_new_time_entry' => 'on')
    timer = TimeLogger.create!(issue: @issue)
    timer.update!(paused: true, time_spent: 5400)
    post :stop, params: {id: timer.id}
    assert_redirected_to controller: 'timelog', action: 'new', issue_id: @issue.id, time_entry: {hours: 1.5}
  end

  def test_other_users_cannot_control_timer_even_if_admin
    timer = TimeLogger.create!(issue: @issue)
    other = create_user
    sign_in(other)
    %i[suspend resume stop delete].each do |action|
      post action, params: {id: timer.id}, xhr: true
      assert_response :forbidden
      assert TimeLogger.exists?(timer.id)
    end
    other.update!(admin: true)
    sign_in(other)
    post :suspend, params: {id: timer.id}, xhr: true
    assert_response :forbidden
  end

  def test_visible_issue_without_log_permission_is_denied
    reader = create_user
    role = Role.create!(name: 'Optimus timer reader', permissions: [:view_issues])
    Member.create!(project: @issue.project, principal: reader, roles: [role])
    sign_in(reader)
    post :start, params: {issue_id: @issue.id}, xhr: true
    assert_response :forbidden
    assert_empty TimeLogger.where(user: reader)
  end

  def test_private_issue_is_not_exposed_to_outsider
    @issue.project.update!(is_public: false)
    sign_in(create_user)
    post :start, params: {issue_id: @issue.id}, xhr: true
    assert_response :not_found
    assert_equal 0, TimeLogger.count
  end

  def test_timer_list_hides_others_without_permission
    timer = TimeLogger.create!(issue: @issue)
    sign_in(create_user)
    get :index
    assert_response :success
    assert_select "#all-timetracker#{timer.id}", count: 0
  end

  def test_anonymous_cannot_start_or_list_timers
    @request.session.clear
    User.current = User.anonymous
    post :start, params: {issue_id: @issue.id}, xhr: true
    assert_response :unauthorized
    assert_equal 0, TimeLogger.count
  end

  def test_mutating_routes_reject_get
    %w[start suspend resume stop delete].each do |action|
      assert_raises(ActionController::RoutingError) do
        @routes.recognize_path("/time_loggers/#{action}", method: :get)
      end
    end
  end

  def test_member_can_track_and_submit_native_time_once
    member = create_user
    role = Role.create!(name: 'Optimus timer logger', permissions: [:view_issues, :log_time])
    Member.create!(project: @issue.project, principal: member, roles: [role])
    sign_in(member)
    travel_to Time.current.change(usec: 0)
    original = TimeEntry.count
    post :start, params: {issue_id: @issue.id}, xhr: true
    assert_response :success
    timer = TimeLogger.find_by!(user: member)
    travel 5400.seconds
    post :stop, params: {id: timer.id}
    assert_response :redirect
    assert_equal original, TimeEntry.count
    assert_equal '1.5', Rack::Utils.parse_nested_query(URI.parse(response.location).query).dig('time_entry', 'hours')
    @controller = TimelogController.new
    @controller.set_request!(@request)
    post :create, params: {time_entry: {project_id: @issue.project_id, issue_id: @issue.id,
      hours: '1.5', spent_on: Date.current.to_s, activity_id: TimeEntryActivity.active.first!.id,
      comments: 'Optimus timer smoke'}}
    assert_response :redirect
    assert_equal original + 1, TimeEntry.count
    entry = TimeEntry.order(:id).last!
    assert_equal member.id, entry.user_id
    assert_equal @issue.id, entry.issue_id
    assert_in_delta 1.5, entry.hours
  end

  def test_other_timer_list_and_delete_follow_project_permissions
    timer = TimeLogger.create!(issue: @issue)
    viewer = create_user
    role = Role.create!(name: 'Optimus timer manager', permissions: [:view_issues, :view_others_time_loggers])
    Member.create!(project: @issue.project, principal: viewer, roles: [role])
    sign_in(viewer)
    get :index
    assert_response :success
    assert_select "#all-timetracker#{timer.id}", count: 1
    post :delete, params: {id: timer.id}
    assert_response :forbidden
    role.update!(permissions: role.permissions + [:delete_others_time_loggers])
    sign_in(viewer.reload)
    post :delete, params: {id: timer.id}
    assert_response :redirect
    refute TimeLogger.exists?(timer.id)
  end

  def test_cannot_resume_or_stop_after_log_permission_removed
    owner = create_user
    sign_in(owner)
    timer = TimeLogger.create!(issue: @issue)
    %i[suspend resume stop].each do |action|
      post action, params: {id: timer.id}, xhr: true
      assert_response :forbidden
      assert TimeLogger.exists?(timer.id)
    end
    post :delete, params: {id: timer.id}
    assert_response :redirect
    refute TimeLogger.exists?(timer.id)
  end

  def test_start_applies_only_configured_valid_status_transition
    target = @issue.new_statuses_allowed_to(@user).find { |status| status.id != @issue.status_id }
    raise 'Need an allowed status transition for the smoke fixture' unless target
    Setting.plugin_time_logger = {'status_transitions' => {@issue.status_id.to_s => target.id.to_s}}
    post :start, params: {issue_id: @issue.id}, xhr: true
    assert_response :success
    assert_equal target.id, @issue.reload.status_id
    post :start, params: {issue_id: @issue.id}, xhr: true
    assert_response :bad_request
    assert_equal target.id, @issue.reload.status_id
  end

  def test_invalid_timer_actions_leave_state_intact
    post :start, params: {issue_id: 0}, xhr: true
    assert_response :not_found
    timer = TimeLogger.create!(issue: @issue)
    post :resume, params: {id: timer.id}, xhr: true
    assert_response :bad_request
    timer.update!(paused: true)
    post :suspend, params: {id: timer.id}, xhr: true
    assert_response :bad_request
    post :stop, params: {id: 0}, xhr: true
    assert_response :not_found
    assert TimeLogger.exists?(timer.id)
  end

  def test_hours_to_seconds_migration_preserves_timer_data
    require Rails.root.join('plugins/time_logger/db/migrate/20201009134528_change_time_spent_to_int')
    @connection.transaction(requires_new: true) do
      @connection.execute('CREATE TEMP TABLE time_loggers (id integer PRIMARY KEY, time_spent double precision DEFAULT 0, started_on timestamp, paused boolean) ON COMMIT DROP')
      @connection.execute("INSERT INTO time_loggers VALUES (1, 1.5, '2026-10-19 10:00:00', true), (2, 0.333333333333, '2026-10-19 11:00:00', false)")
      assert @connection.select_value("SELECT pg_my_temp_schema() = relnamespace FROM pg_class WHERE oid = 'time_loggers'::regclass")
      before = @connection.select_all('SELECT id, started_on, paused FROM time_loggers ORDER BY id').to_a
      ChangeTimeSpentToInt.new.migrate(:up)
      assert_equal [5400, 1200], @connection.select_values('SELECT time_spent FROM time_loggers ORDER BY id')
      assert_equal before, @connection.select_all('SELECT id, started_on, paused FROM time_loggers ORDER BY id').to_a
      ChangeTimeSpentToInt.new.migrate(:down)
      hours = @connection.select_values('SELECT time_spent FROM time_loggers ORDER BY id')
      assert_in_delta 1.5, hours[0]
      assert_in_delta 1.0 / 3, hours[1]
      raise ActiveRecord::Rollback
    end
  end

  private

  def post(action, **options)
    @request.headers['X-CSRF-Token'] = @controller.send(:form_authenticity_token)
    super
  end

  def sign_in(user)
    @request.session[:user_id] = user.id
    @request.session[:tk] = user.generate_session_token
    User.current = user
  end

  def create_user
    User.create!(login: "optimus-timer-#{User.maximum(:id).to_i + 1}", firstname: 'Timer', lastname: 'Smoke',
                 mail: "optimus-timer-#{User.maximum(:id).to_i + 1}@example.invalid", status: User::STATUS_ACTIVE)
  end
end