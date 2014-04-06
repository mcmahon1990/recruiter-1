class SubjectsController < ApplicationController
  before_action :authenticate_user!
  before_action :raise_if_not_admin, only: [:destroy, :destroy_all, :index]
  before_action :raise_if_not_experimenter, only: [:assign, :remained]

  def index
    @experiment = Experiment.find(params[:experiment_id])
    @subjects = @experiment.subjects
    render 'index'
  end
  def destroy
    @experiment = Experiment.find(params[:experiment_id])
    @subject_id = params[:subject]
    @experiment.subjects.delete params[:subject]
  end
  def destroy_all
    @experiment = Experiment.find(params[:experiment_id])
    @experiment.subjects.delete_all
    redirect_to experiment_path @experiment
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
    @subjects = Subject
      .joins("LEFT OUTER JOIN (select user_id, count(*) as registrations_count from registrations group by user_id) r1 on (r1.user_id = users.id)")
      .joins("LEFT OUTER JOIN (select user_id, count(*) as shown_up_count from registrations where registrations.shown_up = true group by user_id) r2 on (r2.user_id = users.id)")
      .where(processed_params)
      .where.not(id: Assignment.where(experiment_id: @experiment.id).pluck(:user_id))
      .where("(#{search_params[:never_been].nil?} or r1.registrations_count = 0)")
      .where("COALESCE((r2.shown_up_count / r1.registrations_count),100) BETWEEN #{attendance.min} and #{attendance.max}").to_a
    @subjects.shuffle!(random: Random.new(1))
    if @subjects.count >= search_params[:required_subjects].to_i
      @assigned_count = search_params[:required_subjects].to_i
      @remained_subjects_count = @subjects.count - search_params[:required_subjects].to_i
      @experiment.subjects << (@subjects.count != 1 ? @subjects[0...@assigned_count] : @subjects)
      Rails.cache.write('remained_subjects', @subjects[@assigned_count..-1])
      render 'assigned'
    else
      Rails.cache.write('remained_subjects', @subjects)
      render 'fault'
    end
  end
  def remained
    @experiment = Experiment.find(search_params[:experiment_id])
    @subjects = Rails.cache.read('remained_subjects')
    @experiment.subjects << @subjects
    @assigned_count = @subjects.count
    @remained_subjects_count = 0
    render 'assigned'
  end
  private
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