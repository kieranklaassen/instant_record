require "digest"
require "instant_record/syncable"

module InstantRecord
  module Syncable
    class_methods do
      # Which records the asker may be sent, for rules a single column cannot
      # say (`sync_scope` is the short form for "its owner's, or everyone's").
      # The block runs on the model, on the server only, with whatever
      # `InstantRecord.config.scope_from` returned for the request, and returns
      # a relation. Declare it inside `server_only`.
      #
      #   server_only do
      #     syncable_to { |user| user ? where(team_id: user.team_ids) : none }
      #   end
      def syncable_to(&block)
        @instant_record_visibility = block
      end

      # Which records the asker may create, change and delete. Without it,
      # what may be seen may be written.
      def writable_by(&block)
        @instant_record_writability = block
      end

      def instant_record_visibility = @instant_record_visibility
      def instant_record_writability = @instant_record_writability || @instant_record_visibility
    end
  end

  # Who may be sent what, and who may write what, on the four sync endpoints.
  # A model says so with `sync_scope :column` or with `syncable_to` and
  # `writable_by`; both are read through here. Server only: none of this is in
  # the browser build, which holds whatever the server chose to send.
  module SyncScope
    RESET = "reset".freeze

    class << self
      # Whoever `config.scope_from` says is asking. A string or nil suits
      # `sync_scope` columns; `syncable_to` blocks are handed it as it is.
      def identity(request)
        InstantRecord.config.scope_from.call(request)
      end

      # The asker as a `sync_scope` column holds it.
      def token(identity)
        identity.to_s.presence
      end

      # A name for the asker that changes when the person behind a browser
      # does (sign in, sign out). It is what the identity says it is
      # (`sync_identity_key`), or its class and id, or itself as a string, and
      # nobody at all has a name too. Not a secret and not a credential: the
      # server always scopes by the request's own identity.
      def key(identity)
        name =
          if identity.respond_to?(:sync_identity_key) then identity.sync_identity_key
          elsif identity.respond_to?(:id) then "#{identity.class.name}:#{identity.id}"
          else identity
          end
        Digest::SHA256.hexdigest(name.to_s.presence || "anonymous")[0, 16]
      end

      # Whether the key a client bootstrapped under is no longer this request's
      # identity. A request that names no key is judged by who it is now: it is
      # a client that synced before keys existed, or no sync client at all.
      def stale?(sent_key, identity)
        sent_key.present? && sent_key != key(identity)
      end

      def scoped?(model)
        !model.instant_record_sync_scope.nil? || !model.instant_record_visibility.nil?
      end

      def visible(model, identity)
        both(model, model.instant_record_visible_to(token(identity)), model.instant_record_visibility, identity)
      end

      def writable(model, identity)
        column = model.instant_record_sync_scope
        both(model, column ? model.where(column => token(identity)) : model.all, model.instant_record_writability, identity)
      end

      def scoped_types
        InstantRecord.syncable_models.select { |model| scoped?(model) }.map(&:name)
      end

      # The models a change of this identity's key empties in a browser: every
      # scoped one, unless the identity names them. An identity whose key
      # leaves part of itself out (the demo's leaves out the browser's own
      # token) says which models the rest decides.
      def reset_types(identity)
        identity.respond_to?(:sync_reset_types) ? identity.sync_reset_types : scoped_types
      end

      # The one event a stale client is sent. It names the types because the
      # browser build cannot know them.
      def reset_event(identity)
        { operation: RESET, types: reset_types(identity), identity: key(identity) }
      end

      # Change-log rows as the events one asker may receive, as [id, event]
      # pairs. The log already keeps a `sync_scope` model's changes to their
      # owner (Change.visible_to). A `syncable_to` model's rule can depend on
      # anything, so it is asked now: a change is sent with the record's state
      # as it stands, never the logged payload, which may predate the record
      # being shared. A record the asker may not see is sent as an empty
      # destroy: nothing to a client that never held it, a revocation to one
      # that did.
      def events_for(changes, identity)
        current = visible_records(changes, identity)
        changes.map do |change|
          model = ruled_model(change.record_type)
          next [change.id, change.as_event] if change.operation == "destroy" || model.nil?

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

      # A column rule and a block rule both hold. As a subquery, since merging
      # two conditions on one column keeps only the second.
      def both(model, rows, block, identity)
        return rows unless block

        ruled = model.instance_exec(identity, &block)
        model.instant_record_sync_scope ? rows.where(model.primary_key => ruled.select(model.primary_key)) : ruled
      end

      # The model behind a logged type, when it has a `syncable_to` rule. Asked
      # of the class itself too: a model left out of `InstantRecord.sync` still
      # logs its changes, and its rule still decides who reads them.
      def ruled_model(type)
        model = InstantRecord.synced_model(type) || type.to_s.safe_constantize
        model if model.respond_to?(:instant_record_visibility) && model.instant_record_visibility
      end

      # One query per `syncable_to` model in the batch.
      def visible_records(changes, identity)
        found = {}
        changes.reject { |change| change.operation == "destroy" }.group_by(&:record_type).each do |type, list|
          model = ruled_model(type)
          next unless model

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
