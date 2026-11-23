require "test_helper"
require "tmpdir"
require "fileutils"
require "sqlite3"

class BranchTest < Minitest::Test
  class RecordingTransport
    attr_reader :posts, :gets, :polls
    attr_accessor :responder

    def initialize
      @posts = []
      @gets = []
      @polls = []
      @responder = nil
    end

    def post_json(path, payload)
      @posts << [path, payload]
      if @responder
        @responder.call(payload)
      else
        results = Array(payload[:mutations]).map do |m|
          { "mutation_id" => m[:id], "status" => "applied", "version" => (m[:base_version] || 0) + 1 }
        end
        { "results" => results }
      end
    end

    def get_json(path)
      @gets << path
      { "cursor" => 1, "records" => [] }
    end

    def each_event(path, &_block)
      @polls << path
    end
  end

  class RecordingNotifier
    attr_reader :notices

    def initialize
      @notices = []
    end

    def records_changed
      @notices << InstantRecord::Client.changes_notice
    end
  end

  def setup
    @model = syncable_model("Task")
    InstantRecord.sync(@model)
    @transport = RecordingTransport.new
    @notifier = RecordingNotifier.new
    InstantRecord::Client.transport = @transport
    InstantRecord::Client.notifier = @notifier
    InstantRecord::Branch.current = nil
    reset_instant_record_tables!
  end

  def teardown
    InstantRecord::Branch.current&.discard! if InstantRecord::Branch.current&.active?
    InstantRecord::Branch.current = nil
    InstantRecord.sync
    InstantRecord::Client.transport = nil
    InstantRecord::Client.notifier = nil
    InstantRecord.instance_variable_set(:@started, false)
  end

  # Runs a test against a real file-backed SQLite database, then restores the
  # shared :memory: connection used by the rest of the test suite.
  def with_file_sqlite
    original_config = ActiveRecord::Base.connection_db_config.configuration_hash.dup
    saved_ddl = ActiveRecord::Base.connection.select_values(
      "SELECT sql FROM sqlite_master WHERE type IN ('table', 'index') AND name NOT LIKE 'sqlite_%' AND sql IS NOT NULL ORDER BY type DESC, name ASC"
    )
    Dir.mktmpdir("ir_branch_test_") do |dir|
      db_path = File.join(dir, "main.sqlite3")
      ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: db_path)
      migrate_test_schema!
      yield db_path, dir
    end
  ensure
    InstantRecord::Branch.current&.discard! if InstantRecord::Branch.current&.active?
    ActiveRecord::Base.connection_handler.clear_all_connections!
    ActiveRecord::Base.establish_connection(original_config)
    saved_ddl.each { |sql| ActiveRecord::Base.connection.execute(sql) }
  end

  def migrate_test_schema!
    ActiveRecord::Migration.suppress_messages do
      ActiveRecord::MigrationContext.new(File.expand_path("../db/migrate", __dir__)).migrate
      ActiveRecord::Schema.define do
        create_table :items, id: :string, force: true do |t|
          t.string :title
          t.string :state
          t.string :owner
          t.integer :server_version, null: false, default: 0
          t.string :sync_state, null: false, default: "synced"
          t.timestamps
        end
      end
    end
  end

  def seed_synced_record(id:, title:, state: "open", owner: "alice", version: 1, updated_at: Time.now.utc - 60)
    InstantRecord::Client.applying_remote do
      @model.create!(
        id: id,
        title: title,
        state: state,
        owner: owner,
        server_version: version,
        sync_state: "synced",
        created_at: updated_at,
        updated_at: updated_at
      )
    end
  end

  def test_branch_requires_local_client_runtime
    on_server do
      error = assert_raises(InstantRecord::Branch::Error) { InstantRecord.branch! }
      assert_match(/local client runtime/, error.message)
    end
  end

  def test_nested_branch_is_refused
    in_browser do
      branch = InstantRecord.branch!(name: "first")
      error = assert_raises(InstantRecord::Branch::Error) { InstantRecord.branch!(name: "second") }
      assert_match(/Already on staging branch 'first'/, error.message)
      branch.discard!
    end
  end

  def test_offline_gate_blocks_all_server_traffic_while_branched
    in_browser do
      InstantRecord.start
      InstantRecord::Client.cursor = 5

      branch = InstantRecord.branch!(name: "offline-sandbox")
      assert InstantRecord.branched?
      assert_equal "offline-sandbox", InstantRecord.branch_name

      @model.create!(id: "draft-1", title: "Never leaves local branch")
      assert_equal 1, branch.staged_count

      refute InstantRecord::Client.sync_pass
      refute InstantRecord::Client.drain
      refute InstantRecord::Client.poll_changes
      refute InstantRecord::Client.bootstrap
      assert_equal :ok, InstantRecord.tick

      assert_empty @transport.posts, "branch mutations must never be posted to the server"
      assert_empty @transport.gets, "branch must never bootstrap from the server"
      assert_empty @transport.polls, "branch must never poll events from the server"

      branch.discard!
      refute InstantRecord.branched?
      assert_nil InstantRecord.branch_name
    end
  end

  def test_env_branch_marker_enforces_offline_gate_for_wasm_hosts
    ENV["INSTANT_RECORD_BRANCH"] = "wasm-preview"
    in_browser do
      assert InstantRecord.branched?
      assert_equal "wasm-preview", InstantRecord.branch_name
      @model.create!(id: "env-1", title: "WASM staged")

      refute InstantRecord::Client.sync_pass
      refute InstantRecord::Client.drain
      assert_empty @transport.posts
    end
  ensure
    ENV.delete("INSTANT_RECORD_BRANCH")
  end

  def test_discard_drops_all_branch_edits_with_zero_main_or_server_impact
    with_file_sqlite do |_db_path, _dir|
      in_browser do
        seed_synced_record(id: "t-1", title: "Keep me", state: "open")
        InstantRecord::Client.cursor = 10

        branch = InstantRecord.branch!(name: "experiment")
        branch_file = branch.path
        assert File.exist?(branch_file)

        @model.create!(id: "t-new", title: "Bulk draft 1")
        @model.find("t-1").update!(title: "Mutated in branch", state: "done")

        assert_equal 2, @model.count
        assert_equal "Mutated in branch", @model.find("t-1").title
        assert_equal 2, branch.staged_count

        diff = branch.preview_diff
        assert_equal 2, diff["count"]
        assert_equal({ "create" => 1, "update" => 1 }, diff["by_operation"])
        assert_equal({ "Task" => 2 }, diff["by_type"])

        result = branch.discard!
        assert result[:discarded]
        assert_equal 2, result[:dropped]
        assert branch.discarded?
        refute File.exist?(branch_file), "discard must clean up the staging SQLite file"

        assert_equal 1, @model.count
        assert_equal "Keep me", @model.find("t-1").title
        assert_equal "open", @model.find("t-1").state
        assert_equal "synced", @model.find("t-1").sync_state
        assert_equal 0, InstantRecord.pending_count
        assert_equal 10, InstantRecord.cursor
        assert_empty @transport.posts
      end
    end
  end

  def test_block_form_auto_discards_on_exception_and_when_unapproved
    in_browser do
      seed_synced_record(id: "t-1", title: "Safe")

      assert_raises(RuntimeError) do
        InstantRecord.branch!(name: "boom") do |_branch|
          @model.find("t-1").update!(title: "Broken")
          raise "agent failed mid-run"
        end
      end
      refute InstantRecord.branched?
      assert_equal "Safe", @model.find("t-1").title
      assert_equal 0, InstantRecord.pending_count

      InstantRecord.branch!(name: "preview-only") do |_branch|
        @model.create!(id: "t-temp", title: "Only previewed")
      end
      refute InstantRecord.branched?
      refute @model.exists?("t-temp")
      assert_equal 0, InstantRecord.pending_count
    end
  end

  def test_approve_and_sync_preserves_concurrent_remote_deltas_on_main
    with_file_sqlite do |_db_path, _dir|
      in_browser do
        base_time = Time.now.utc - 120
        seed_synced_record(id: "t-1", title: "Original 1", state: "open", version: 1, updated_at: base_time)
        seed_synced_record(id: "t-2", title: "Original 2", state: "open", version: 1, updated_at: base_time)
        seed_synced_record(id: "t-3", title: "Delete me", state: "open", version: 1, updated_at: base_time)
        InstantRecord::Client.cursor = 42

        branch = InstantRecord.branch!(name: "bulk-triage")

        # Bulk edits inside the isolated staging branch:
        @model.find("t-1").update!(state: "done")
        @model.create!(id: "t-branch-new", title: "Created on branch", state: "open")
        @model.find("t-3").destroy!

        # Concurrent remote deltas arrive on `main` DURING branch review:
        branch.on_main do
          InstantRecord::Client.apply_events([
            {
              "type" => "Task", "id" => "t-remote-new", "operation" => "create", "version" => 1, "cursor" => 43,
              "attributes" => {
                "id" => "t-remote-new", "title" => "Arrived on main during review", "state" => "open",
                "owner" => "bob", "updated_at" => Time.now.utc.iso8601(6)
              }
            },
            {
              "type" => "Task", "id" => "t-2", "operation" => "update", "version" => 2, "cursor" => 44,
              "attributes" => {
                "id" => "t-2", "title" => "Updated on main during review", "state" => "open",
                "owner" => "bob", "updated_at" => Time.now.utc.iso8601(6)
              }
            }
          ])
        end

        # Branch preview still shows isolated snapshot (not polluted by main).
        refute @model.exists?("t-remote-new")
        assert_equal "Original 2", @model.find("t-2").title

        # Approve & Sync replays ONLY the branch mutations onto current `main`.
        report = branch.approve!(sync: true)
        assert report[:approved]
        assert_equal 3, report[:applied]
        assert_equal 0, report[:skipped]
        assert_empty report[:conflicts]
        assert report[:synced]

        # Concurrent remote deltas on `main` are 100% preserved!
        assert_equal "Arrived on main during review", @model.find("t-remote-new").title
        assert_equal "Updated on main during review", @model.find("t-2").title
        assert_equal 44, InstantRecord.cursor

        # Approved branch edits are applied and synced!
        assert_equal "done", @model.find("t-1").state
        assert_equal "synced", @model.find("t-1").sync_state
        assert_equal "Created on branch", @model.find("t-branch-new").title
        refute @model.exists?("t-3")
        assert_equal 0, InstantRecord.pending_count

        # Server received exactly the 3 branch mutations in one batch.
        assert_equal 1, @transport.posts.size
        posted = @transport.posts.sole.last[:mutations]
        assert_equal %w[t-1 t-branch-new t-3], posted.map { |m| m[:record_id] }
      end
    end
  end

  def test_concurrent_main_column_merge_preserves_both_remote_and_branch_fields
    with_file_sqlite do |_db_path, _dir|
      in_browser do
        t0 = Time.now.utc - 120
        t_remote = Time.now.utc - 60
        seed_synced_record(id: "t-merge", title: "Original title", state: "open", owner: "alice", version: 1, updated_at: t0)

        branch = InstantRecord.branch!(name: "column-merge")
        # Branch updates ONLY `state` at `Time.now.utc` (newer than `t_remote`).
        @model.find("t-merge").update!(state: "done")

        # Meanwhile, an older remote delta on `main` updated `title` and bumped server_version to 2.
        branch.on_main do
          InstantRecord::Client.apply_change(
            "type" => "Task", "id" => "t-merge", "operation" => "update", "version" => 2,
            "attributes" => {
              "id" => "t-merge", "title" => "Remote renamed title", "state" => "open",
              "owner" => "alice", "updated_at" => t_remote.iso8601(6)
            }
          )
        end

        report = branch.approve!(sync: false)
        assert_equal 1, report[:applied]
        assert_equal 0, report[:skipped]

        merged = @model.find("t-merge")
        assert_equal "Remote renamed title", merged.title, "remote column edit must survive branch replay"
        assert_equal "done", merged.state, "branch column edit must apply on top"
        assert_equal "pending", merged.sync_state
        assert_equal 2, InstantRecord::OutboxMutation.sole.base_version, "base_version must rebase onto current main server_version"
      end
    end
  end

  def test_concurrent_newer_remote_edit_on_same_record_respects_lww_and_reports_conflict
    with_file_sqlite do |_db_path, _dir|
      in_browser do
        t0 = Time.now.utc - 120
        t_branch = Time.now.utc - 30
        t_remote_newer = Time.now.utc + 30
        seed_synced_record(id: "t-conflict", title: "Original", state: "open", version: 1, updated_at: t0)
        seed_synced_record(id: "t-clean", title: "Clean original", state: "open", version: 1, updated_at: t0)

        branch = InstantRecord.branch!(name: "conflict-lww")
        row = @model.find("t-conflict")
        row.update!(title: "Branch stale edit", updated_at: t_branch)
        @model.find("t-clean").update!(title: "Branch clean edit")

        # A strictly newer remote update arrives on `main` for `t-conflict`.
        branch.on_main do
          InstantRecord::Client.apply_change(
            "type" => "Task", "id" => "t-conflict", "operation" => "update", "version" => 2,
            "attributes" => {
              "id" => "t-conflict", "title" => "Newer remote winner", "state" => "open",
              "updated_at" => t_remote_newer.iso8601(6)
            }
          )
        end

        report = branch.approve!(sync: false, conflict: :lww)
        assert_equal 1, report[:applied]
        assert_equal 1, report[:skipped]
        assert_equal 1, report[:conflicts].size
        assert_equal "stale", report[:conflicts].first["reason"]
        assert_equal "t-conflict", report[:conflicts].first["record_id"]

        # Newer remote row is protected; clean branch edit still landed!
        assert_equal "Newer remote winner", @model.find("t-conflict").title
        assert_equal "synced", @model.find("t-conflict").sync_state
        assert_equal "Branch clean edit", @model.find("t-clean").title
        assert_equal "pending", @model.find("t-clean").sync_state
        assert_equal ["t-clean"], InstantRecord::OutboxMutation.ordered.pluck(:record_id)
      end
    end
  end

  def test_branch_wins_strategy_restamps_stale_edit_so_approval_supersedes_remote
    with_file_sqlite do |_db_path, _dir|
      in_browser do
        t0 = Time.now.utc - 120
        t_branch = Time.now.utc - 30
        t_remote_newer = Time.now.utc + 30
        seed_synced_record(id: "t-override", title: "Original", version: 1, updated_at: t0)

        branch = InstantRecord.branch!(name: "override")
        @model.find("t-override").update!(title: "Approved branch override", updated_at: t_branch)

        branch.on_main do
          InstantRecord::Client.apply_change(
            "type" => "Task", "id" => "t-override", "operation" => "update", "version" => 2,
            "attributes" => {
              "id" => "t-override", "title" => "Remote edit", "updated_at" => t_remote_newer.iso8601(6)
            }
          )
        end

        report = branch.approve!(sync: false, conflict: :branch_wins)
        assert_equal 1, report[:applied]
        assert_equal 0, report[:skipped]
        assert_equal "Approved branch override", @model.find("t-override").title

        outbox = InstantRecord::OutboxMutation.sole
        assert_operator Time.parse(outbox.changes_payload["updated_at"]), :>, t_remote_newer
      end
    end
  end

  def test_concurrent_remote_destroy_during_review_skips_orphaned_branch_update_and_destroy_cleanly
    with_file_sqlite do |_db_path, _dir|
      in_browser do
        seed_synced_record(id: "t-gone-upd", title: "Will be deleted remotely")
        seed_synced_record(id: "t-gone-del", title: "Both delete this")
        seed_synced_record(id: "t-keep", title: "Still alive")

        branch = InstantRecord.branch!(name: "remote-deletes")
        @model.find("t-gone-upd").update!(title: "Branch edited deleted row")
        @model.find("t-gone-del").destroy!
        @model.find("t-keep").update!(title: "Branch edited live row")

        branch.on_main do
          InstantRecord::Client.apply_change("type" => "Task", "id" => "t-gone-upd", "operation" => "destroy")
          InstantRecord::Client.apply_change("type" => "Task", "id" => "t-gone-del", "operation" => "destroy")
        end

        report = branch.approve!(sync: false)
        assert_equal 1, report[:applied]
        assert_equal 2, report[:skipped]
        reasons = report[:conflicts].to_h { |c| [c["record_id"], c["reason"]] }
        assert_equal "record not found", reasons["t-gone-upd"]
        assert_equal "already destroyed", reasons["t-gone-del"]

        refute @model.exists?("t-gone-upd")
        refute @model.exists?("t-gone-del")
        assert_equal "Branch edited live row", @model.find("t-keep").title
      end
    end
  end

  def test_pre_existing_main_outbox_mutations_are_not_duplicated_on_approve
    with_file_sqlite do |_db_path, _dir|
      in_browser do
        # Pre-fork offline write on `main` (already in main's outbox before branching).
        @model.create!(id: "t-pre-fork", title: "Created on main before fork")
        assert_equal 1, InstantRecord.pending_count

        branch = InstantRecord.branch!(name: "after-offline-main")
        assert_equal 0, branch.staged_count, "pre-fork outbox rows belong to main, not the branch"

        @model.create!(id: "t-branch-only", title: "Created on branch")
        assert_equal 1, branch.staged_count

        # Simulate main draining its pre-fork mutation while the branch is open!
        branch.on_main do
          InstantRecord::Client.drain
          assert_equal 0, InstantRecord.pending_count
        end

        report = branch.approve!(sync: false)
        assert_equal 1, report[:applied]
        assert_equal 0, report[:skipped]
        assert_equal ["t-branch-only"], InstantRecord::OutboxMutation.ordered.pluck(:record_id)
        assert @model.exists?("t-pre-fork")
        assert @model.exists?("t-branch-only")
      end
    end
  end

  def test_external_sqlite_connection_writing_to_main_file_during_review_is_preserved
    with_file_sqlite do |db_path, _dir|
      in_browser do
        seed_synced_record(id: "t-1", title: "Initial")

        branch = InstantRecord.branch!(name: "external-writer")
        @model.create!(id: "t-branch", title: "From branch")

        # An external SQLite process/connection writes directly to `main.sqlite3`
        # while this process is connected to the isolated branch SQLite file.
        ext = SQLite3::Database.new(db_path)
        now = Time.now.utc.iso8601(6)
        ext.execute(
          "INSERT INTO items (id, title, state, owner, server_version, sync_state, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
          ["t-external", "Written directly to main file", "open", "peer", 3, "synced", now, now]
        )
        ext.close

        refute @model.exists?("t-external"), "branch file is physically isolated from main.sqlite3"

        report = branch.approve!(sync: false)
        assert_equal 1, report[:applied]
        assert_equal "Written directly to main file", @model.find("t-external").title
        assert_equal "From branch", @model.find("t-branch").title
      end
    end
  end

  def test_end_to_end_approve_syncs_cleanly_through_server_mutation_applier
    with_file_sqlite do |_db_path, dir|
      # Stand up a separate server-side SQLite database to exercise the real
      # MutationApplier end to end against replayed branch mutations!
      server_db = File.join(dir, "server.sqlite3")
      client_db = File.join(dir, "main.sqlite3")

      # Seed initial synced row on both client and server.
      t0 = Time.now.utc - 120
      in_browser { seed_synced_record(id: "t-shared", title: "v1", state: "open", version: 1, updated_at: t0) }
      InstantRecord::Client.cursor = 1

      # Snapshot client DB (including WAL) to server DB as the authoritative starting point.
      InstantRecord::Branch::SqliteStore.backup_database(ActiveRecord::Base.connection.raw_connection, server_db)

      # Wire transport to run the real InstantRecord::MutationApplier against server_db.
      # Note: test_helper's `with_runtime` is non-reentrant, so swap `browser?`
      # directly for the server call while inside `in_browser`.
      @transport.responder = lambda do |payload|
        results = nil
        ActiveRecord::Base.connection_handler.clear_all_connections!
        ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: server_db)
        InstantRecord.singleton_class.define_method(:browser?) { false }
        begin
          results = Array(payload[:mutations]).map do |m|
            InstantRecord::MutationApplier.apply(m.symbolize_keys)
          end
        ensure
          InstantRecord.singleton_class.define_method(:browser?) { true }
          ActiveRecord::Base.connection_handler.clear_all_connections!
          ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: client_db)
        end
        { "results" => results.map(&:stringify_keys) }
      end

      in_browser do
        branch = InstantRecord.branch!(name: "e2e-agent")
        @model.find("t-shared").update!(state: "done")
        @model.create!(id: "t-agent-1", title: "Agent created 1", state: "open")
        @model.create!(id: "t-agent-2", title: "Agent created 2", state: "open")
        @model.find("t-agent-2").update!(title: "Agent refined 2")

        # Concurrent remote record created on server & delivered to `main` during review.
        branch.on_main do
          InstantRecord::Client.apply_change(
            "type" => "Task", "id" => "t-remote", "operation" => "create", "version" => 1,
            "attributes" => {
              "id" => "t-remote", "title" => "Remote peer task", "state" => "open",
              "updated_at" => Time.now.utc.iso8601(6)
            }
          )
        end

        report = branch.approve!(sync: true)
        assert_equal 4, report[:applied]
        assert_equal 0, report[:skipped]
        assert report[:synced]
        assert_equal 0, InstantRecord.pending_count
        assert_equal "synced", @model.find("t-shared").sync_state
        assert_equal "synced", @model.find("t-agent-1").sync_state
        assert_equal "Agent refined 2", @model.find("t-agent-2").title
        assert_equal "Remote peer task", @model.find("t-remote").title
      end

      # Verify the authoritative server database converged with every approved branch mutation!
      ActiveRecord::Base.connection_handler.clear_all_connections!
      ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: server_db)
      assert_equal "done", @model.find("t-shared").state
      assert_equal 2, @model.find("t-shared").server_version
      assert_equal "Agent created 1", @model.find("t-agent-1").title
      assert_equal "Agent refined 2", @model.find("t-agent-2").title
      assert_equal 2, @model.find("t-agent-2").server_version
    end
  end

  def test_memory_sqlite_branching_approve_and_concurrent_on_main_work_seamlessly
    in_browser do
      seed_synced_record(id: "m-1", title: "In memory")

      branch = InstantRecord.branch!(name: "mem-branch")
      @model.create!(id: "m-branch", title: "Staged in memory")

      branch.on_main do
        InstantRecord::Client.apply_change(
          "type" => "Task", "id" => "m-remote", "operation" => "create", "version" => 1,
          "attributes" => { "id" => "m-remote", "title" => "Remote in memory", "updated_at" => Time.now.utc.iso8601(6) }
        )
      end

      report = branch.approve!(sync: false)
      assert_equal 1, report[:applied]
      assert_equal %w[m-1 m-branch m-remote], @model.order(:id).pluck(:id)
      assert_equal 1, InstantRecord.pending_count
    end
  end

  def test_replay_mutations_is_idempotent_and_validates_conflict_strategy
    in_browser do
      mutation = {
        "id" => "mut-idem-1",
        "record_type" => "Task",
        "record_id" => "t-idem",
        "operation" => "create",
        "changes" => { "id" => "t-idem", "title" => "Once only" },
        "base_version" => 0
      }

      first = InstantRecord::Branch.replay_mutations([mutation])
      assert_equal 1, first["applied"]
      assert_equal 0, first["skipped"]

      second = InstantRecord::Branch.replay_mutations([mutation])
      assert_equal 0, second["applied"]
      assert_equal 1, second["skipped"]
      assert_equal 1, InstantRecord.pending_count

      assert_raises(ArgumentError) do
        InstantRecord::Branch.replay_mutations([mutation], conflict: :invalid)
      end
    end
  end

  def test_double_approve_or_discard_is_refused
    in_browser do
      branch = InstantRecord.branch!(name: "once")
      branch.discard!
      assert_raises(InstantRecord::Branch::Error) { branch.discard! }
      assert_raises(InstantRecord::Branch::Error) { branch.approve! }
      assert_raises(InstantRecord::Branch::Error) { branch.staged_mutations }
    end
  end
end
