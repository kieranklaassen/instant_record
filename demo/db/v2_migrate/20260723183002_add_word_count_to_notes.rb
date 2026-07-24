# The v2 release. Deliberately NOT in db/migrate/ — see app/models/release.rb
# for why, and for how it gets run.
class AddWordCountToNotes < ActiveRecord::Migration[8.1]
  # A migration-local model, the standard Rails guard, and here it is load
  # bearing: the real Note includes InstantRecord::Syncable, whose after_update
  # callback records an outbox mutation for every row it touches. A backfill
  # through that would queue one client mutation per existing note and replay
  # the whole table at the server — the exact failure db/seeds.rb had to be
  # taught to avoid. update_columns skips callbacks too; both together mean the
  # outbox cannot move while this runs, which is what the demo claims.
  class Note < ActiveRecord::Base
    self.table_name = "notes"
  end

  def up
    add_column :notes, :word_count, :integer

    # The migration's own model has to be told the column arrived; the app's
    # Note is reset by Release.ship, which owns the long-lived VM's view.
    Note.reset_column_information
    Note.find_each { |note| note.update_columns(word_count: note.body.to_s.split.size) }
  end

  def down
    remove_column :notes, :word_count
  end
end
