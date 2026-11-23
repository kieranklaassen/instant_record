require "test_helper"
require "action_view"
require File.expand_path("../app/helpers/instant_record/sync_notices_helper", __dir__)

class SyncNoticesHelperTest < Minitest::Test
  def setup
    reset_instant_record_tables!
    views_path = File.expand_path("../app/views", __dir__)
    lookup = ActionView::LookupContext.new([views_path])
    @view = ActionView::Base.with_empty_template_cache.new(lookup, {}, nil)
    @view.extend(InstantRecord::SyncNoticesHelper)
  end

  def test_renders_hidden_empty_container_when_no_notices
    html = @view.instant_record_sync_notices

    assert_includes html, 'id="instant-record-sync-notices"'
    assert_includes html, 'data-notice-count="0"'
    assert_includes html, "hidden"
    refute_includes html, "ir-sync-notice__btn"
  end

  def test_renders_quarantined_notices_with_diffs_and_action_forms
    conflict = InstantRecord::SyncNotice.record!(
      kind: "conflict",
      record_type: "Note",
      record_id: "n-1",
      operation: "update",
      reason: "Overwritten by a newer server change",
      attempted_changes: { "title" => "Offline <draft>" },
      server_attributes: { "title" => "Server winner" },
      server_version: 3
    )
    rejected = InstantRecord::SyncNotice.record!(
      kind: "rejected",
      record_type: "Issue",
      record_id: "i-2",
      operation: "create",
      reason: "Title is not allowed",
      attempted_changes: { "title" => "reject me" }
    )

    html = @view.instant_record_sync_notices(return_to: "/todo")

    assert_includes html, 'data-notice-count="2"'
    refute_includes html, "hidden>"
    assert_includes html, "Conflict"
    assert_includes html, "Rejected"
    assert_includes html, "Offline &lt;draft&gt;"
    assert_includes html, "Server winner"
    assert_includes html, "Title is not allowed"
    assert_includes html, %(action="/instant_record/sync_notices/#{conflict.id}/retry")
    assert_includes html, %(action="/instant_record/sync_notices/#{conflict.id}/fork")
    assert_includes html, %(action="/instant_record/sync_notices/#{conflict.id}/dismiss")
    assert_includes html, %(action="/instant_record/sync_notices/#{rejected.id}/retry")
    assert_includes html, 'name="return_to" value="/todo"'
  end

  def test_filters_by_record_type_and_supports_custom_mount_path
    InstantRecord::SyncNotice.record!(
      kind: "conflict", record_type: "Note", record_id: "n-1",
      operation: "update", reason: "stale", attempted_changes: { "title" => "a" }
    )
    InstantRecord::SyncNotice.record!(
      kind: "rejected", record_type: "Issue", record_id: "i-1",
      operation: "create", reason: "nope", attempted_changes: { "title" => "b" }
    )

    html = @view.instant_record_sync_notices(record_type: "Issue", mount_path: "/sync")

    assert_includes html, 'data-notice-count="1"'
    assert_includes html, "Issue (create)"
    refute_includes html, "Note (update)"
    assert_includes html, 'action="/sync/sync_notices/'
  end
end
