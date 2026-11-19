class AddScopeToInstantRecordChanges < ActiveRecord::Migration[8.1]
  # Whose change this is, for a model that declares sync_scope. NULL is a
  # change every client may hear of.
  def change
    add_column :instant_record_changes, :scope, :string
  end
end
