class Issue < ApplicationRecord
  include InstantRecord::Syncable

  validates :title, presence: true, length: { maximum: 200 }

  scope :open, -> { where.not(state: "done") }

  # Server-only rule to demonstrate rejection (AE4): the browser accepts the
  # write optimistically; the server refuses it and the client rolls back.
  server_only do
    validates :title, exclusion: { in: ["reject me"], message: "is not allowed by the server" }
  end
end
