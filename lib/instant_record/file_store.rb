require "fileutils"
require "rack/files"

module InstantRecord
  # Where the server keeps the bytes of records that declare `sync_file`: one
  # file per record, in a folder on disk. A file arrives in pieces, each
  # appended to a partial that belongs to one upload, and becomes the record's
  # file when its last piece lands. It is never written again.
  #
  # `InstantRecord.config.file_store` may be anything that answers what this
  # does (a bucket, say). Keys are made by InstantRecord::Files and are safe
  # as paths.
  class FileStore
    # A piece that does not start where the partial ends. `offset` is where
    # the next piece must start.
    class Misplaced < StandardError
      attr_reader :offset

      def initialize(offset)
        @offset = offset
        super("the next piece starts at #{offset}")
      end
    end

    # A piece larger than the store's configured chunk size. `limit` is the
    # largest piece accepted in bytes.
    class ChunkTooLarge < StandardError
      attr_reader :limit

      def initialize(limit)
        @limit = limit
        super("a piece may be at most #{limit} bytes")
      end
    end

    UPLOAD = /\A[\w-]{1,64}\z/

    # Default upload/download piece size: 512 KiB, safely below common 1-2 MB
    # reverse-proxy body ceilings (such as nginx's 1m default).
    DEFAULT_CHUNK_SIZE = 512 * 1024

    attr_reader :root

    def initialize(root, chunk_size: nil)
      @root = File.expand_path(root.to_s)
      @chunk_size = chunk_size.nil? ? nil : validate_chunk_size!(chunk_size)
    end

    def chunk_size
      configured = @chunk_size || (defined?(InstantRecord) && InstantRecord.config.file_chunk_size) || DEFAULT_CHUNK_SIZE
      validate_chunk_size!(configured)
    end

    def exist?(key) = File.file?(path(key))
    def size(key) = File.size(path(key))

    # How many bytes of an upload are held.
    def offset(key, upload)
      File.size?(partial(key, upload)) || 0
    end

    # Add a piece of `length` bytes that starts at `at`. Answers where the
    # next one starts. A piece that arrives twice, or out of turn, is refused
    # and nothing is written: the lock makes two senders of one upload take
    # turns, and the second finds the partial already past its piece.
    def append(key, upload, io, at:, length:)
      limit = chunk_size
      raise ChunkTooLarge.new(limit) if length > limit

      target = partial(key, upload)
      FileUtils.mkdir_p(File.dirname(target))
      File.open(target, File::RDWR | File::CREAT | File::BINARY) do |file|
        file.flock(File::LOCK_EX)
        raise Misplaced.new(file.size) unless file.size == at

        file.seek(at)
        written = IO.copy_stream(io, file, length)
        unless written == length
          # A piece cut short on the way is dropped whole, so the partial only
          # ever holds pieces that arrived in full.
          file.truncate(at)
          raise Misplaced.new(at)
        end
        file.fsync
        at + written
      end
    end

    # The upload is whole: it becomes the record's file. The first to finish
    # wins, and a file that is already there is left as it is.
    def finish(key, upload)
      source = partial(key, upload)
      if exist?(key)
        FileUtils.rm_f(source)
      else
        File.rename(source, path(key))
      end
      true
    end

    def discard(key, upload)
      FileUtils.rm_f(partial(key, upload))
    end

    # The record is gone: its file and every partial of it.
    def delete(key)
      FileUtils.rm_f([path(key), *partials(key)])
    end

    # Partials no piece has reached since `before`: uploads that were given up.
    # Answers how many were removed.
    def sweep(before:)
      stale = Dir.glob("**/*.part", base: root).map { |file| File.join(root, file) }
        .select { |file| File.mtime(file) < before }
      FileUtils.rm_f(stale)
      stale.size
    end

    # The file as a Rack response: ranges, HEAD and If-Modified-Since are
    # Rack::Files's.
    def serve(key, request)
      Rack::Files.new(root, {}, "application/octet-stream").serving(request, path(key))
    end

    def path(key) = File.join(root, key)

    private

    def partial(key, upload)
      raise ArgumentError, "not an upload's name: #{upload.inspect}" unless UPLOAD.match?(upload.to_s)

      "#{path(key)}.#{upload}.part"
    end

    def validate_chunk_size!(value)
      raise ArgumentError, "chunk_size must be a positive integer, got #{value.inspect}" unless value.is_a?(Integer) && value.positive?

      value
    end

    def partials(key)
      folder, name = File.split(path(key))
      return [] unless File.directory?(folder)

      Dir.children(folder)
        .select { |entry| entry.start_with?("#{name}.") && entry.end_with?(".part") }
        .map { |entry| File.join(folder, entry) }
    end
  end
end
