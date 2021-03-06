gem 'delayed_job_active_record'
class UsersController < InheritedResources::Base

  before_action :authenticate_user!, :except => ['password_change_action']
  before_action :raise_if_not_admin, only: [:invite_users, :deactivate, :unassign, :unassign_all, :assigned, :suspend_user, :unsuspend_user]
  before_action :raise_if_not_experimenter, only: [:assign, :register, :unregister, :remained]

  actions :all
  custom_actions :resource => [:suspend_user, :unsuspend_user, :assigned, :unassign, :unassign_all, :register, :unregister], :collection => [:deactivate, :suspended, :invite_users]

  respond_to :js, :only => [:add, :unregister, :unassign, :reset_user]
  respond_to :json, :only => [:update, :invite_users]

  def index
    @users = User.where.not(id: current_user.id).order("type ASC, active ASC, last_name ASC, first_name ASC")
    if params[:q].present?
      @users = @users.find_by_query(params[:q])
    end
    @users = @users.paginate(:page => params[:page])
    index!
  end
  def suspended
    @users = User.where.not(id: current_user.id).where(suspended: true).order("type ASC, active ASC, last_name ASC, first_name ASC")
    if params[:q].present?
      @users = @users.find_by_query(params[:q])
    end
    @users = @users.paginate(:page => params[:page])
    render 'index'
  end
  def suspend_user
    @user = User.find(params[:id])
    @user.suspend!
    redirect_to user_path(@user) + '#settings'
  end
  def unsuspend_user
    @user = User.find(params[:id])
    @user.unsuspend!
    redirect_to user_path(@user) + '#settings'
  end
  def self.delayed_invite_users(emails, email_text)
    emails.each do |email|
      UserMailer.delay.send_custom(email, 'ICES Invitation', email_text)
    end
  end
  def invite_users
    emails = params[:emails].strip.split(/\s+/)
    emails = emails - Subject.all.pluck(:email)
    email_text = params[:email][:value]
    UsersController.delay.delayed_invite_users(emails, email_text)
    redirect_to users_path
  end
  def reset_user
    User.find(params[:id]).reset_password
  end
  def reset_users
    users = User.where("encrypted_password = ''")
    users.each do |user|
      user.reset_password
    end
    redirect_to users_path
  end
  def deactivate_users
    Subject.update_all(active: false)
    Subject.all.each do |user|
      UserMailer.delay.deactivation(user)
    end
    redirect_to users_path
  end
  def self.delayed_remind_to_fill_users(email_text)
    users = Subject.all - Subject.profile_full
    users.each do |user|
      UserMailer.delay.send_custom(user.email, 'ICES Reminder', email_text)
    end
  end
  def remind_to_fill_users
    email_text = params[:email][:value]
    UsersController.delay.delayed_remind_to_fill_users(email_text)
    redirect_to users_path
  end
  def unsuspend_users
    users = Subject.suspended
    users.each do |user|
      user.unsuspend!
    end
    redirect_to users_path
  end

  def assigned
    @experiment = Experiment.find(params[:experiment_id])
  end

  def unassign
    @experiment = Experiment.find(params[:experiment_id])
    @user_id = params[:user_id]
    Registration.where(session_id: @experiment.sessions, user_id: @user_id).delete_all
    @experiment.users.delete params[:user_id]
  end

  def unassign_all
    @experiment = Experiment.find(params[:experiment_id])
    Registration.where(session_id: @experiment.sessions, user_id: @experiment.users).delete_all
    @experiment.users.delete_all
    redirect_to experiment_path @experiment
  end

  def register
    session = Session.find(params[:session_id])
    subject = Subject.find(params[:user_id])
    subject.sessions << session
    redirect_to experiment_users_path(session.experiment)
  end

  def unregister
    session = Session.find(params[:session_id])
    session.users.delete params[:user_id]
    @session_id = params[:session_id]
    @user_id = params[:user_id]
  end

  def assign
    @experiment = Experiment.find(search_params[:experiment_id])
    processed_params = Hash.new
    %w[gender class_year profession major ethnicity].each do |f|
      processed_params[f] = search_params[f]
    end
    %w[birth_year year_started years_resident current_gpa attendance].each do |f|
      processed_params[f] = ((search_params["#{f}_from"].to_s == '' ? view_context.custom_range[f].min : search_params["#{f}_from"].to_i)..
          (search_params["#{f}_to"].to_s == '' ? view_context.custom_range[f].max : search_params["#{f}_to"].to_i))
    end
    attendance = processed_params["attendance"]
    processed_params.delete "attendance"

    restricted_subjects = Assignment.where(experiment_id: @experiment.id).pluck(:user_id)
    restricted_subjects |= Subject.inactive.pluck(:id)
    restricted_subjects |= Subject.suspended.pluck(:id)
    restricted_subjects |= Subject.locked.pluck(:id)

    if params[:never_been]
      restricted_subjects |= Registration.all.pluck(:user_id)
    elsif params[:never_been_similar]
      same = []
      @experiment.categories.each do |f|
        same |= f.experiments.pluck(:id)
      end
      sessions_with_same_categories = Session.where(experiment_id: same)
      restricted_subjects |= Registration.where(session_id: sessions_with_same_categories).pluck(:user_id)
    end
    @subjects = Subject
    .profile_full
    .active
    .joins("LEFT OUTER JOIN (select user_id, count(*) as registrations_count from registrations left outer join sessions on (sessions.id = registrations.session_id) where sessions.finished = 't' group by user_id) r1 on (r1.user_id = users.id)")
    .joins("LEFT OUTER JOIN (select user_id, count(*) as shown_up_count from registrations left outer join sessions on (sessions.id = registrations.session_id) where sessions.finished = 't' and registrations.shown_up = 't' group by user_id) r2 on (r2.user_id = users.id)")
    .where("COALESCE((r2.shown_up_count / r1.registrations_count),100) BETWEEN #{attendance.min} and #{attendance.max}")
    .where(processed_params)
    .where.not(id: restricted_subjects).to_a
    @subjects.shuffle!(random: Random.new(1))
    if @subjects.count >= search_params[:required_subjects].to_i
      @assigned_count = search_params[:required_subjects].to_i
      @remained_subjects_count = @subjects.count - search_params[:required_subjects].to_i
      @experiment.users << (@subjects.count != 1 ? @subjects[0...@assigned_count] : @subjects)
      Rails.cache.write('remained_subjects', @subjects[@assigned_count..-1])
      render 'assign_action_success'
    else
      Rails.cache.write('remained_subjects', @subjects)
      render 'assign_action_fail'
    end
  end

  def remained
    @experiment = Experiment.find(search_params[:experiment_id])
    @subjects = Rails.cache.read('remained_subjects')
    @experiment.users << @subjects
    @assigned_count = @subjects.count
    @remained_subjects_count = 0
    render 'assign_action_success'
  end

  def update
    update!
    @user.save :validate => false
  end

  def permitted_params
    params.permit(:id, :user => [:cred, :type])
  end

  def search_params
    params.permit(
        :birth_year_from,
        :birth_year_to,
        :year_started_from,
        :year_started_to,
        :years_resident_from,
        :years_resident_to,
        :current_gpa_from,
        :current_gpa_to,
        :attendance_from,
        :attendance_to,
        :never_been,
        :never_been_similar,
        :required_subjects,
        :experiment_id,
        {:gender => []},
        {:class_year => []},
        {:profession => []},
        {:major => []},
        {:ethnicity => []}
    )
  end
end