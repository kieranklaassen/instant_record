require "active_support/concern"

module InstantRecord
  module SyncEndpoint
    extend ActiveSupport::Concern

    included do
      class_attribute :sync_headers, instance_accessor: false, default: InstantRecord::CORS_HEADERS

      before_action :apply_sync_headers
      rescue_from InstantRecord::Unauthorized, with: -> { head :unauthorized }
      rescue_from InstantRecord::Forbidden, with: -> { head :forbidden }
    end

    def preflight
      head :no_content
    end

    private

    def apply_sync_headers
      headers.merge!(self.class.sync_headers)
    end

    def eager_load_models!
      Rails.application.eager_load! if defined?(Rails) && Rails.application && !Rails.application.config.eager_load
    end
  end
end
