class Note < ApplicationRecord
  include InstantRecord::Syncable

  # PostgreSQL can reuse prepared queries while the migration demo changes
  # this table. An explicit projection gives each schema its own query.
  self.enumerate_columns_in_select_statements = true

  validates :title, presence: true, length: { maximum: 200 }
  validates :body, length: { maximum: 10_000 }

  # v2's behaviour, guarded by a schema question rather than a runtime one.
  #
  # One model file, two schemas: the local database is on v1 until the visitor
  # ships v2 on /migrate, so code that reads the new column has to cope with it
  # not being there yet. That is the standing cost of migrating a database you
  # do not control the boot order of — the code arrives before the DDL does.
  # Existing rows get their count from the migration's backfill; new ones get
  # it here.
  before_save :count_words, if: -> { has_attribute?(:word_count) }

  # Older clients include their derived count in queued mutations. Accept
  # the field on either schema and compute the authoritative count from body.
  def word_count=(_client_count)
  end

  private

  def count_words
    self[:word_count] = body.to_s.split.size
  end
end
