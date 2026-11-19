require "digest"
require "instant_record/syncable"

module InstantRecord
  class Configuration
    # Who a sync request comes from: a callable given the request, returning
    # whatever the app uses for a person, or nil when nobody is signed in.
    #
    #   InstantRecord.configure do |config|
    #     config.sync_identity = ->(request) { User.find_by(id: request.session[:user_id]) }
    #   end
    #
    # Unset, the sync endpoints behave as they always have: every synced record
    # goes to every client and any client may write it.
    attr_accessor :sync_identity
  end

  module Syncable
    class_methods do
      # Which records an identity may see. The block runs on the model, on the
      # server only, and returns a relation; it is given nil for a signed-out
      # request. Declare it inside `server_only`.
      #
      #   server_only do
      #     syncable_to { |user| user ? where(owner_id: user.id) : none }
      #   end
      def syncable_to(&block)
        @instant_record_visibility = block
      end

      # Which records an identity may create, change and delete. Without it,
      # what an identity may see is what it may write.
      def writable_by(&block)
        @instant_record_writability = block
      end

      def instant_record_visibility = @instant_record_visibility
      def instant_record_writability = @instant_record_writability || @instant_record_visibility
    end
  end

  # Per-identity scoping of the four sync endpoints. Server only: none of this
  # is part of the browser build, which holds whatever the server chose to send.
  module SyncScope
    ANONYMOUS = "anonymous".freeze
    RESET = "reset".freeze

    class << self
      def enabled? = !InstantRecord.config.sync_identity.nil?

      def identity(request)
        InstantRecord.config.sync_identity&.call(request)
      end

      # An opaque name for an identity. Not a secret and not a credential: the
      # server always scopes by the request's own identity. The key only lets a
      # client and the server notice that the person behind a browser changed.
      def key(identity)
        return nil unless enabled?

        raw =
          if identity.nil? then ANONYMOUS
          elsif identity.respond_to?(:sync_identity_key) then identity.sync_identity_key
          else "#{identity.class.name}:#{identity.id}"
          end
        Digest::SHA256.hexdigest(raw.to_s)[0, 16]
      end

      # Whether the key a client bootstrapped under is no longer this request's
      # identity. A request that names no key is judged by who it is now: it is
      # a client that synced before identities existed, or no sync client at all.
      def stale?(sent_key, identity)
        enabled? && sent_key.present? && sent_key != key(identity)
      end

      def scoped?(model)
        enabled? && !model.instant_record_visibility.nil?
      end

      def visible(model, identity)
        scoped?(model) ? model.instance_exec(identity, &model.instant_record_visibility) : model.all
      end

      def writable(model, identity)
        scoped?(model) ? model.instance_exec(identity, &model.instant_record_writability) : model.all
      end

      def scoped_types
        InstantRecord.syncable_models.select { |model| scoped?(model) }.map(&:name)
      end

      # The one event a stale client is sent. It names the scoped types because
      # the browser build cannot know them.
      def reset_event(identity)
        { operation: RESET, types: scoped_types, identity: key(identity) }
      end

      # Change-log rows as the events one identity may receive, as [id, event]
      # pairs. A change to a scoped model is sent with the record's state now,
      # never the logged payload, which may predate the record being shared. A
      # record the identity may not see is sent as an empty destroy: nothing to
      # a client that never held it, a revocation to one that did.
      def events_for(changes, identity)
        return changes.map { |change| [change.id, change.as_event] } unless enabled?

        current = visible_records(changes, identity)
        changes.map do |change|
          model = InstantRecord.synced_model(change.record_type)
          next [change.id, change.as_event] if change.operation == "destroy" || model.nil? || !scoped?(model)

          record = current[[change.record_type, change.record_id]]
          event =
            if record
              InstantRecord.record_payload(record).merge(operation: change.operation)
            else
              { type: change.record_type, id: change.record_id, operation: "destroy", version: 0, attributes: {} }
            end
          [change.id, event]
        end
      end

      private

      # One query per scoped model in the batch.
      def visible_records(changes, identity)
        found = {}
        changes.reject { |change| change.operation == "destroy" }.group_by(&:record_type).each do |type, list|
          model = InstantRecord.synced_model(type)
          next unless model && scoped?(model)

          model.connection_pool.with_connection do
            model.uncached do
              visible(model, identity).where(model.primary_key => list.map(&:record_id).uniq).each do |record|
                found[[type, record.id]] = record
              end
            end
          end
        end
        found
      end
    end
  end
end
