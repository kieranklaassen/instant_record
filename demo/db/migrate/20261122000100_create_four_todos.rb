# The lists of the three todo apps at /compare that Rails serves, one table
# each, so that each app is whole and none sees another's rows. The fourth
# app, /instant, keeps its list in issues, which syncs. Spelled out and not
# looped: the compiled build reads a migration without running it.
class CreateFourTodos < ActiveRecord::Migration[8.1]
  def change
    create_table :plain_todos do |t|
      t.string :title, null: false
      t.string :state, null: false, default: "open"
      t.timestamps
    end

    create_table :hotwire_todos do |t|
      t.string :title, null: false
      t.string :state, null: false, default: "open"
      t.timestamps
    end

    create_table :inertia_todos do |t|
      t.string :title, null: false
      t.string :state, null: false, default: "open"
      t.timestamps
    end
  end
end
