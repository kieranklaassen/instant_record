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

ActiveRecord::Schema[8.1].define(version: 2026_11_22_000100) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "assistant_chats", id: :string, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "server_version", default: 0, null: false
    t.string "sync_state", default: "synced", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.string "visitor_id"
    t.index ["visitor_id", "created_at"], name: "index_assistant_chats_on_visitor_id_and_created_at"
  end

  create_table "assistant_turns", id: :string, force: :cascade do |t|
    t.string "assistant_chat_id", null: false
    t.string "author", default: "", null: false
    t.datetime "created_at", null: false
    t.string "engine", default: "server", null: false
    t.text "prompt", null: false
    t.text "reply", default: "", null: false
    t.integer "server_version", default: 0, null: false
    t.string "sync_state", default: "synced", null: false
    t.datetime "updated_at", null: false
    t.string "visitor_id"
    t.index ["assistant_chat_id", "created_at", "id"], name: "idx_on_assistant_chat_id_created_at_id_dab59499ed"
  end

  create_table "auth_notes", id: :string, force: :cascade do |t|
    t.string "audience", default: "owner", null: false
    t.text "body", default: "", null: false
    t.datetime "created_at", null: false
    t.string "owner_id", null: false
    t.integer "server_version", default: 0, null: false
    t.string "sync_state", default: "synced", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
  end

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

  create_table "headline_writes", force: :cascade do |t|
    t.boolean "arrived_from_server", default: false, null: false
    t.datetime "created_at", null: false
    t.boolean "discarded_on_arrival", default: false, null: false
    t.string "text", null: false
    t.datetime "updated_at", null: false
    t.string "writer", null: false
    t.datetime "written_at", null: false
  end

  create_table "headlines", id: :string, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "server_version", default: 0, null: false
    t.string "sync_state", default: "synced", null: false
    t.string "text", null: false
    t.datetime "updated_at", null: false
    t.string "writer", null: false
  end

  create_table "hotwire_todos", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "state", default: "open", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
  end

  create_table "inertia_todos", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "state", default: "open", null: false
    t.string "title", null: false
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
    t.string "scope"
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
    t.datetime "release_at"
    t.text "rollback_payload"
    t.datetime "updated_at", null: false
    t.index ["release_at"], name: "index_instant_record_outbox_on_release_at"
  end

  create_table "instant_record_sync_metadata", primary_key: "key", id: :string, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "value"
  end

  create_table "instant_record_sync_notices", id: :string, force: :cascade do |t|
    t.text "attempted_changes"
    t.datetime "created_at", null: false
    t.datetime "dismissed_at"
    t.string "kind", null: false
    t.string "mutation_id"
    t.string "operation", null: false
    t.string "reason", default: "", null: false
    t.string "record_id", null: false
    t.string "record_type", null: false
    t.text "server_attributes"
    t.integer "server_version", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["dismissed_at", "created_at"], name: "idx_on_dismissed_at_created_at_56c2ef3c71"
    t.index ["mutation_id"], name: "index_instant_record_sync_notices_on_mutation_id"
    t.index ["record_type", "record_id"], name: "index_instant_record_sync_notices_on_record_type_and_record_id"
  end

  create_table "issues", id: :string, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "server_version", default: 0, null: false
    t.string "state", default: "open", null: false
    t.string "sync_state", default: "synced", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
  end

  create_table "mail_entries", id: :string, force: :cascade do |t|
    t.string "address"
    t.string "author", null: false
    t.text "body"
    t.datetime "created_at", null: false
    t.string "kind", null: false
    t.string "mailbox_id", null: false
    t.string "parent_id"
    t.integer "server_version", default: 0, null: false
    t.string "subject"
    t.string "sync_state", default: "synced", null: false
    t.datetime "updated_at", null: false
    t.index ["mailbox_id", "server_version"], name: "index_mail_entries_on_mailbox_id_and_server_version"
    t.index ["parent_id"], name: "index_mail_entries_on_parent_id"
  end

  create_table "mailboxes", id: :string, force: :cascade do |t|
    t.integer "revision", default: 0, null: false
  end

  create_table "messages", id: :string, force: :cascade do |t|
    t.text "body", null: false
    t.string "channel_id", null: false
    t.string "chat_user_id", null: false
    t.datetime "created_at", null: false
    t.string "parent_message_id"
    t.integer "server_version", default: 0, null: false
    t.string "sync_state", default: "synced", null: false
    t.datetime "updated_at", null: false
    t.index ["channel_id", "created_at", "id"], name: "index_messages_on_channel_id_and_created_at_and_id"
    t.index ["channel_id"], name: "index_messages_on_channel_id"
    t.index ["parent_message_id", "created_at"], name: "index_messages_on_parent_message_id_and_created_at"
  end

  create_table "notes", id: :string, force: :cascade do |t|
    t.text "body", default: "", null: false
    t.datetime "created_at", null: false
    t.integer "server_version", default: 0, null: false
    t.string "sync_state", default: "synced", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
  end

  create_table "plain_todos", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "state", default: "open", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
  end
end
