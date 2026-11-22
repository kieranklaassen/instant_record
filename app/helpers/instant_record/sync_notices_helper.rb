module InstantRecord
  # View helpers for surfacing quarantined InstantRecord::SyncNotice rows in
  # Hotwire / ERB pages. Works in both CRuby Rails and compiled browser builds.
  module SyncNoticesHelper
    def instant_record_sync_notices(notices: nil, record_type: nil, record_id: nil, mount_path: nil, return_to: nil, id: "instant-record-sync-notices")
      list =
        if notices.nil?
          scope = InstantRecord::SyncNotice.active.recent
          scope = scope.where(record_type: record_type.to_s) if record_type
          scope = scope.where(record_id: record_id.to_s) if record_id
          scope.to_a
        else
          Array(notices)
        end

      base = (mount_path || instant_record_mount_path).to_s.sub(%r{/+\z}, "")
      back = return_to || (respond_to?(:request) && request ? request.fullpath : "/")

      render partial: "instant_record/sync_notices/notices", locals: {
        notices: list,
        base_path: "#{base}/sync_notices",
        return_to: back,
        dom_id: id
      }
    end

    def instant_record_notice_diff(notice)
      notice.respond_to?(:field_diffs) ? notice.field_diffs : []
    end

    private

    def instant_record_mount_path
      if defined?(Rails) && Rails.application && Rails.application.config.respond_to?(:instant_record)
        configured = Rails.application.config.instant_record.mount_path
        return configured if configured.is_a?(String)
      end
      InstantRecord::DEFAULT_MOUNT_PATH
    end
  end
end
