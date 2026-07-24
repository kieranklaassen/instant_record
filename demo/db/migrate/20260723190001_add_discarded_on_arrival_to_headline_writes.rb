class AddDiscardedOnArrivalToHeadlineWrites < ActiveRecord::Migration[8.1]
  def change
    # A value the server sent that last-write-wins threw away on arrival. It is
    # in the ledger but was never in the row, so it cannot be labelled by
    # position: the ledger is ordered by insertion and this row is appended last
    # while holding the oldest value.
    add_column :headline_writes, :discarded_on_arrival, :boolean, null: false, default: false
  end
end
