class Note < ApplicationRecord
  include InstantRecord::Syncable

  validates :title, presence: true, length: { maximum: 200 }
  validates :body, length: { maximum: 10_000 }
  after_save :update_local_count

  def word_count
    Release.word_count(id)
  end

  def update_local_count
    Release.update_count(id, body) unless Release.pending?
  end
end
