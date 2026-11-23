require "test_helper"
require "sqlite3"

module InstantRecord
  class ShellsControllerTest < ActionDispatch::IntegrationTest
    include ActiveJob::TestHelper

    setup do
      @shells = Pathname(Dir.mktmpdir("instant_record_shells"))
      @root, Shell.root = Shell.root, @shells
      Slack::Seeds.apply
      AuthNote.seed_demo
      AssistantChat.delete_all
      AssistantTurn.delete_all
      AssistantChat.create!(id: "chat-public", title: "Example chat")
      AssistantChat.create!(id: "chat-v1", title: "Visitor 1 private chat", visitor_id: "v1")
      AssistantChat.create!(id: "chat-v2", title: "Visitor 2 private chat", visitor_id: "v2")
    end

    teardown do
      Shell.root = @root
      FileUtils.rm_rf(@shells)
    end

    def sign_in(id) = post("/auth/session", params: { person: id }, as: :json)
    def sign_out = post("/auth/session/sign_out", params: {}, as: :json)

    def request_grant(scope: nil, fingerprint: Shell.fingerprint)
      params = { fingerprint: fingerprint }
      params[:scope] = scope if scope
      get "/instant_record/shell", params: params
    end

    def download_shell(scope: nil)
      request_grant(scope: scope)
      assert_response :success
      assert_equal "private, no-store", response.headers["cache-control"]
      assert_includes response.headers["vary"].to_s, "Authorization"
      assert_includes response.headers["vary"].to_s, "Cookie"

      grant = response.parsed_body
      file_url = "/instant_record#{grant.fetch("path")}"
      file_url += "&scope=#{CGI.escape(scope)}" if scope
      get file_url
      assert_response :success
      assert_equal "private, no-store", response.headers["cache-control"]
      assert_equal "nosniff", response.headers["x-content-type-options"]
      assert Shell.valid_sqlite?(response.body)

      file = @shells.join("client-#{SecureRandom.hex(4)}.sqlite3")
      file.binwrite(response.body)
      [SQLite3::Database.new(file.to_s, results_as_hash: true), grant]
    end

    test "missing shell returns 204 and schedules ShellBuildJob, then serves built shell" do
      assert_enqueued_with(job: ShellBuildJob) { request_grant }
      assert_response :no_content
      assert_equal "private, no-store", response.headers["cache-control"]

      perform_enqueued_jobs
      assert_no_enqueued_jobs { request_grant }
      assert_response :success
      assert_equal(Change.maximum(:id) || 0, response.parsed_body["cursor"])
    end

    test "mismatched fingerprint returns 204 without enqueuing a build" do
      assert_no_enqueued_jobs { request_grant(fingerprint: "0" * 64) }
      assert_response :no_content
    end

    test "shell respects SyncScope for both auth sessions and visitor tokens and never leaks across callers" do
      # Build shells for signed-out visitor v1, signed-out visitor v2, and signed-in Ada (with v1).
      perform_enqueued_jobs { request_grant(scope: "v1") }
      db_v1, grant_v1 = download_shell(scope: "v1")
      assert_equal %w[auth-welcome], db_v1.execute("SELECT id FROM auth_notes ORDER BY id").map { |r| r["id"] }
      assert_equal %w[chat-public chat-v1], db_v1.execute("SELECT id FROM assistant_chats ORDER BY id").map { |r| r["id"] }

      perform_enqueued_jobs { request_grant(scope: "v2") }
      db_v2, _grant_v2 = download_shell(scope: "v2")
      assert_equal %w[chat-public chat-v2], db_v2.execute("SELECT id FROM assistant_chats ORDER BY id").map { |r| r["id"] }

      sign_in "ada"
      perform_enqueued_jobs { request_grant(scope: "v1") }
      db_ada, grant_ada = download_shell(scope: "v1")
      assert_equal %w[auth-ada auth-lunch auth-payroll auth-welcome], db_ada.execute("SELECT id FROM auth_notes ORDER BY id").map { |r| r["id"] }
      saved = db_ada.execute("SELECT key, value FROM instant_record_sync_metadata").to_h { |r| [r["key"], r["value"]] }
      assert_equal grant_ada["cursor"].to_s, saved["cursor"]
      assert_equal grant_ada["identity"], saved["identity"]
      assert_equal Shell.fingerprint, saved["shell_fingerprint"]
      assert_equal Shell.models.sort.join(","), saved["compiled_models"]
      assert_match(/\A\d{20}\z/, saved["schema_version"])

      # Ben cannot download Ada's signed shell file.
      sign_in "ben"
      get "/instant_record#{grant_ada.fetch("path")}&scope=v1"
      assert_response :not_found

      # A signed-out caller cannot download Ada's signed shell file.
      sign_out
      get "/instant_record#{grant_ada.fetch("path")}&scope=v1"
      assert_response :not_found

      # Visitor v2 cannot download visitor v1's signed shell file.
      get "/instant_record#{grant_v1.fetch("path")}&scope=v2"
      assert_response :not_found

      # Forged and expired tokens are rejected.
      get "/instant_record/shell/file", params: { token: "forged", scope: "v1" }
      assert_response :not_found
      travel Shell::URL_LIFETIME + 1.second do
        get "/instant_record#{grant_v1.fetch("path")}&scope=v1"
        assert_response :not_found
      end
    end

    test "shell applies SyncWindow identically to bootstrap" do
      55.times do |i|
        Message.create!(
          id: "shell-msg-#{format('%03d', i)}",
          channel_id: "channel-general",
          chat_user_id: "bot-ursula",
          body: "backlog #{i}",
          created_at: (200 - i).minutes.ago,
          updated_at: (200 - i).minutes.ago
        )
      end

      perform_enqueued_jobs { request_grant }
      db, _grant = download_shell

      general_ids = db.execute("SELECT id FROM messages WHERE channel_id = 'channel-general'").map { |r| r["id"] }
      assert_equal 50, general_ids.size
      refute_includes general_ids, "shell-msg-000"
      assert_includes general_ids, "welcome-channel-general"
    end

    test "shell beyond retention is not served and stale shell triggers background rebuild" do
      perform_enqueued_jobs { request_grant }
      stamp = Shell.latest(Shell.partition_key(DemoAsker.new(nil, nil))).cursor

      # Advance the change log past REBUILD_AFTER_CHANGES.
      Change.create!(id: stamp + Shell::REBUILD_AFTER_CHANGES + 1, record_type: "Issue", record_id: "i1", operation: "create", version: 1, created_at: Time.current)
      assert_enqueued_with(job: ShellBuildJob) { request_grant }
      assert_response :success
      assert_equal stamp, response.parsed_body["cursor"]

      # Advance past SERVE_WITHIN_CHANGES.
      Change.create!(id: stamp + Shell::SERVE_WITHIN_CHANGES + 1, record_type: "Issue", record_id: "i2", operation: "create", version: 2, created_at: Time.current)
      request_grant
      assert_response :no_content
    end

    test "preflight answers 204 with CORS headers" do
      options "/instant_record/shell"
      assert_response :no_content
      assert_equal "*", response.headers["access-control-allow-origin"]
      assert_includes response.headers["access-control-allow-headers"].to_s, "authorization"
    end
  end
end
