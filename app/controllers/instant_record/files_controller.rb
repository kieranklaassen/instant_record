module InstantRecord
  # The bytes of records that declare `sync_file`. A browser writes a file to
  # its own disk first and sends it here in pieces when it has a connection;
  # another device asks for it when it is wanted there.
  #
  # The record decides who may do either. A file may be read by whoever may be
  # sent its record and written by whoever may write it, and a record the
  # asker may not see answers as a missing one does. The record itself arrives
  # through the mutations endpoint, so a file sent before its record has been
  # is 404 too, and the browser tries again.
  class FilesController < ActionController::API
    CORS = InstantRecord::CORS_HEADERS.merge(
      "access-control-allow-methods" => "GET, HEAD, PUT, OPTIONS",
      "access-control-allow-headers" => "content-type, range",
      "access-control-expose-headers" => "accept-ranges, content-length, content-range, x-instant-record-chunk-size"
    ).freeze

    # What a file is said to be comes from whoever sent it, so a browser is
    # told to keep it as a download and to run nothing in it.
    INERT = {
      "content-disposition" => "attachment",
      "x-content-type-options" => "nosniff",
      "content-security-policy" => "default-src 'none'; sandbox",
      "cache-control" => "private, no-cache"
    }.freeze

    before_action { headers.merge!(CORS) }
    before_action :find_model, except: :preflight

    def preflight
      head :no_content
    end

    # The file, or the part of it a Range header names.
    def show
      record = SyncScope.visible(@model, identity).find_by(id: params[:id])
      key = record && Files.key(@model, record.id)
      return head :not_found unless key && store.exist?(key)

      status, file_headers, body = store.serve(key, request)
      headers.merge!(file_headers).merge!(INERT)
      headers["content-type"] = Files.content_type(record)
      headers["x-instant-record-chunk-size"] = chunk_size.to_s
      self.status = status
      self.response_body = body
    end

    # Where an upload stands, so one that was cut off goes on from there.
    def progress
      return head :not_found unless (key = writable_key)
      return render json: { complete: true, offset: store.size(key), chunk_size: chunk_size } if store.exist?(key)
      return head :bad_request unless upload?

      render json: { complete: false, offset: store.offset(key, params[:upload]), chunk_size: chunk_size }
    end

    # One piece of an upload: `size` bytes in all, this piece starting at
    # `offset`. The last piece makes the file. A file that is already here
    # stays as it is, and the answer says so.
    def update
      return head :unsupported_media_type unless request.media_type == "application/octet-stream"
      return head :not_found unless (key = writable_key)
      return render json: { complete: true, offset: store.size(key), chunk_size: chunk_size } if store.exist?(key)
      return head :bad_request unless upload?
      length = request.content_length
      return head :length_required unless length.positive?

      size = params[:size].to_i
      at = params[:offset].to_i
      limit = chunk_size
      return refuse("a file needs a size") unless size.positive?
      return refuse("larger than this server takes", 413) if size > Files.max_size(@model)
      return refuse("not the size the record gives") if @declared && @declared != size
      return refuse("past the end of the file") if at.negative? || at + length > size
      return render json: { error: "piece larger than this server takes", chunk_size: limit }, status: 413 if length > limit

      reached = store.append(key, params[:upload], request.body, at: at, length: length)
      store.finish(key, params[:upload]) if reached == size
      render json: { complete: reached == size, offset: reached, chunk_size: limit }
    rescue FileStore::Misplaced => e
      render json: { complete: false, offset: e.offset, chunk_size: chunk_size }, status: :conflict
    rescue FileStore::ChunkTooLarge => e
      render json: { error: "piece larger than this server takes", chunk_size: e.limit }, status: 413
    end

    private

    def store = Files.store
    def chunk_size = Files.chunk_size(@model)
    def identity = SyncScope.identity(request)
    def upload? = FileStore::UPLOAD.match?(params[:upload].to_s)

    def find_model
      @model = Files.model(params[:type])
      head :not_found unless @model
    end

    # Where the file of a record the sender may write is kept.
    def writable_key
      record = SyncScope.writable(@model, identity).find_by(id: params[:id])
      return unless record

      @declared = Files.declared_size(record)
      Files.key(@model, record.id)
    end

    def refuse(reason, status = :unprocessable_entity)
      render json: { error: reason }, status: status
    end
  end
end
