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

    # Default upload/download piece size: 512 KiB, safely below common 1-2 MB
    # reverse-proxy body ceilings.
    DEFAULT_CHUNK_SIZE = FileStore::DEFAULT_CHUNK_SIZE

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

      # Maximum bytes accepted per upload piece (and advertised to clients).
      # A model may choose a smaller chunk size, never one larger than the
      # server's configured or store-enforced ceiling.
      def chunk_size(model = nil)
        model_size = model.respond_to?(:instant_record_file_chunk_size) ? model.instant_record_file_chunk_size : nil
        server_limit = store.respond_to?(:chunk_size) ? store.chunk_size : (InstantRecord.config.file_chunk_size || DEFAULT_CHUNK_SIZE)
        unless server_limit.is_a?(Integer) && server_limit.positive?
          raise ArgumentError, "chunk_size must be a positive integer, got #{server_limit.inspect}"
        end
        return server_limit if model_size.nil?
        unless model_size.is_a?(Integer) && model_size.positive?
          raise ArgumentError, "chunk_size must be a positive integer, got #{model_size.inspect}"
        end

        [model_size, server_limit].min
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
