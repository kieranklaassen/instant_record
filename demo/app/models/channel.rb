class Channel < ApplicationRecord
  include InstantRecord::Syncable

  KINDS = %w[channel dm].freeze

  has_many :messages, dependent: :destroy

  validates :name, presence: true
  validates :kind, inclusion: { in: KINDS }
  validates :dm_user_id, presence: true, if: :dm?

  scope :channels, -> { where(kind: "channel").order(:name) }
  scope :dms, -> { where(kind: "dm").order(:name) }

  def dm? = kind == "dm"

  def dm_user
    ChatUser.find_by(id: dm_user_id) if dm?
  end
end
