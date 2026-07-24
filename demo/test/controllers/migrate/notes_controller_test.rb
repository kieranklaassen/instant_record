require "test_helper"

module Migrate
  class NotesControllerTest < ActionDispatch::IntegrationTest
    setup { @verbose_was, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false }

    teardown do
      Note.reset_column_information
      ActiveRecord::Migration.verbose = @verbose_was
    end

    test "index lists the columns the database actually has, read from the connection" do
      Note.create!(title: "a written note", body: "one two three")

      get migrate_root_url

      assert_response :success
      assert_includes response.body, "a written note"
      assert_select "ul.columns li", count: Release.local_columns.size
      Release.local_columns.each { |column| assert_select "ul.columns li", text: column }
      assert_select "ul.columns li", text: Release::COLUMN, count: 0,
        message: "v1 has no word_count, so the page must not list it as a column it holds"
      assert_includes response.body, "(#{Release.version}) pending"
    end

    test "create persists a note and redirects back" do
      post migrate_notes_url, params: { note: { title: "new note", body: "hello" } }

      assert_redirected_to migrate_root_path
      assert Note.exists?(title: "new note")
    end

    test "shipping runs the migration and the page then shows the backfilled column" do
      Note.create!(title: "older", body: "two words")

      post migrate_ship_url

      assert_redirected_to migrate_root_path
      follow_redirect!

      assert_select "ul.columns li", text: Release::COLUMN, count: 1
      assert_select "table.notes td.num", text: "2"
      assert_includes response.body, "(#{Release.version}) applied"
      assert_equal 2, Note.find_by!(title: "older").word_count
    end
  end
end
