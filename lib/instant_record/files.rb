require "digest"
require "instant_record/syncable"
require "instant_record/file_store"

module InstantRecord
  # The server's half of `sync_file`: where a record's bytes are kept, and
  # when they go. Who may read and write them is the record's own rule
  # (SyncScope), asked by FilesController. Server only: the browser keeps its
  # copy in the origin's private file system (frontend/files.js).
  module Files
    # An id that is safe as a file's name is used as it is.
    PLAIN_ID = /\A[\w-]{1,128}\z/

    # The most bytes taken for one file where neither the model nor the
    # configuration names a number: two gigabytes.
    MAX_SIZE = 2 * 1024 * 1024 * 1024

    class << self
      def store
        InstantRecord.config.file_store ||= FileStore.new(Rails.root.join("storage", "instant_record"))
      end

      def carried_by?(model)
        model.respond_to?(:instant_record_sync_file) && !!model.instant_record_sync_file
      end

      # The model behind a type in an address, when its records carry files.
      def model(type)
        found = InstantRecord.synced_model(type)
        found if found && carried_by?(found)
      end

      # Where a record's file is kept. Any other id is kept under its digest,
      # behind a mark no plain id can start with.
      def key(model, id)
        id = id.to_s
        name = PLAIN_ID.match?(id) ? id : "~#{Digest::SHA256.hexdigest(id)}"
        File.join(model.name.underscore, name)
      end

      # The most bytes the server takes for one record of this model.
      def max_size(model)
        model.instant_record_file_max_size || InstantRecord.config.max_file_size || MAX_SIZE
      end

      # What the record says its file is, where the model has the columns.
      def declared_size(record)
        record[:byte_size] if record.has_attribute?(:byte_size)
      end

      def content_type(record)
        (record[:content_type].presence if record.has_attribute?(:content_type)) || "application/octet-stream"
      end

      # A logged destroy takes the record's file with it. Every destroy on the
      # server is logged, whoever made it, so this is the one place that has
      # to know.
      def forget(change)
        return unless change.operation == "destroy"

        found = InstantRecord.synced_model(change.record_type) || change.record_type.to_s.safe_constantize
        store.delete(key(found, change.record_id)) if found && carried_by?(found)
      end

      # Called once per load of the Change model (the engine's to_prepare).
      def forget_on_destroy(log = InstantRecord::Change)
        log.after_commit(on: :create) { InstantRecord::Files.forget(self) }
      end
    end
  end
end
