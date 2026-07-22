# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_07_22_000003) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "channels", id: :string, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "dm_user_id"
    t.string "kind", default: "channel", null: false
    t.string "name", null: false
    t.integer "server_version", default: 0, null: false
    t.string "sync_state", default: "synced", null: false
    t.datetime "updated_at", null: false
  end

  create_table "chat_users", id: :string, force: :cascade do |t|
    t.boolean "bot", default: false, null: false
    t.datetime "created_at", null: false
    t.string "handle", null: false
    t.string "name", null: false
    t.integer "server_version", default: 0, null: false
    t.string "sync_state", default: "synced", null: false
    t.datetime "updated_at", null: false
  end

  create_table "instant_record_applied_mutations", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "mutation_id", null: false
    t.text "result_payload"
    t.index ["mutation_id"], name: "index_instant_record_applied_mutations_on_mutation_id", unique: true
  end

  create_table "instant_record_changes", force: :cascade do |t|
    t.text "attributes_payload"
    t.datetime "created_at", null: false
    t.string "operation", null: false
    t.string "record_id", null: false
    t.string "record_type", null: false
    t.integer "version", default: 0, null: false
    t.index ["record_type", "record_id"], name: "index_instant_record_changes_on_record_type_and_record_id"
  end

  create_table "instant_record_outbox", id: :string, force: :cascade do |t|
    t.integer "base_version", default: 0, null: false
    t.text "changes_payload"
    t.datetime "created_at", null: false
    t.string "operation", null: false
    t.string "record_id", null: false
    t.string "record_type", null: false
    t.datetime "updated_at", null: false
  end

  create_table "instant_record_sync_metadata", primary_key: "key", id: :string, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "value"
  end

  create_table "issues", id: :string, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "server_version", default: 0, null: false
    t.string "state", default: "open", null: false
    t.string "sync_state", default: "synced", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
  end

  create_table "messages", id: :string, force: :cascade do |t|
    t.text "body", null: false
    t.string "channel_id", null: false
    t.string "chat_user_id", null: false
    t.datetime "created_at", null: false
    t.integer "server_version", default: 0, null: false
    t.string "sync_state", default: "synced", null: false
    t.datetime "updated_at", null: false
    t.index ["channel_id"], name: "index_messages_on_channel_id"
  end
end
