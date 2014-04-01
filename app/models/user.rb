class User < ActiveRecord::Base
  has_paper_trail

  has_many :experiments
  has_one :profile, inverse_of: :user

  accepts_nested_attributes_for :profile

  before_validation :set_canonical_name
  before_save :default_values

  validates_presence_of   :email, :first_name, :last_name, :gsharp
  validates_uniqueness_of :email, :case_sensitive => false

  validates_uniqueness_of :username, :case_sensitive => false

  def name
    "#{self.first_name} #{self.last_name}"
  end

  def is_experimenter?
    self.type == "Administrator" or self.type == "Experimenter"
  end
  def is_administrator?
    self.type == "Administrator"
  end
  def is_subject?
    self.type == "Subject"
  end

  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :trackable, :validatable,
         :confirmable, :lockable, :async
  [:first_name, :last_name].each do |attribute|
    normalize_attribute attribute do |value|
      value.is_a?(String) ? value.titleize.strip : value
    end
  end
private
  def set_canonical_name
    self.username = self.email.split(/@/).first
  end
  def default_values
    self.type ||= 'Subject'
  end
end
