class Issue < ApplicationRecord
  include InstantRecord::Syncable

  validates :title, presence: true

  scope :open, -> { where.not(state: "done") }

  # Server-only rule to demonstrate rejection (AE4): the browser model has no
  # network, so it accepts the write optimistically; the server refuses it.
  unless InstantRecord.browser?
    validates :title, exclusion: { in: ["reject me"], message: "is not allowed by the server" }
  end
end
