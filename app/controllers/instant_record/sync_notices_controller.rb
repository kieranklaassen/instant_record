module InstantRecord
  # Lists and resolves quarantined InstantRecord::SyncNotice rows (retry, fork,
  # dismiss) for both Hotwire HTML forms and React/JSON callers.
  class SyncNoticesController < ActionController::Base
    helper InstantRecord::SyncNoticesHelper
    skip_forgery_protection if: -> { InstantRecord.browser? }

    def index
      @notices = filtered_notices
      respond_to do |format|
        format.json { render json: { ok: true, notices: @notices.map(&:as_notice) } }
        format.html do
          render partial: "instant_record/sync_notices/notices",
            locals: {
              notices: @notices,
              base_path: "#{mount_path}/sync_notices",
              return_to: safe_return_to,
              dom_id: "instant-record-sync-notices"
            },
            layout: false
        end
      end
    end

    def retry
      resolve_action("retry")
    end

    def fork
      resolve_action("fork")
    end

    def dismiss
      resolve_action("dismiss")
    end

    private

    def resolve_action(action)
      result = SyncNotice.resolve(params[:id], action: action, overrides: override_params)
      respond_to do |format|
        format.json { render json: result }
        format.html { redirect_to safe_return_to, status: :see_other }
      end
    rescue ActiveRecord::RecordInvalid, ArgumentError => e
      respond_to do |format|
        format.json do
          render json: { ok: false, error: e.message, notices: SyncNotice.active.recent.map(&:as_notice) },
            status: :unprocessable_entity
        end
        format.html { redirect_to safe_return_to, alert: e.message, status: :see_other }
      end
    end

    def filtered_notices
      scope = SyncNotice.active.recent
      scope = scope.where(record_type: params[:record_type].to_s) if params[:record_type].present?
      scope = scope.where(record_id: params[:record_id].to_s) if params[:record_id].present?
      scope.to_a
    end

    def override_params
      raw = params[:overrides]
      return {} unless raw.respond_to?(:to_unsafe_h) || raw.is_a?(Hash)

      raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw
    end

    def safe_return_to
      target = params[:return_to].to_s
      return target if target.start_with?("/") && !target.start_with?("//")

      "/"
    end

    def mount_path
      configured = Rails.application.config.instant_record.mount_path if defined?(Rails) && Rails.application
      (configured.is_a?(String) ? configured : InstantRecord::DEFAULT_MOUNT_PATH).sub(%r{/+\z}, "")
    end
  end
end
