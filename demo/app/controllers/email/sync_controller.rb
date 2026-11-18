module Email
  class SyncController < ActionController::API
    before_action do
      headers.merge!(InstantRecord::CORS_HEADERS)
      headers["Cache-Control"] = "no-store"
    end
    before_action :load_mailbox, except: :preflight

    def preflight
      head :no_content
    end

    def bootstrap
      cursor = @mailbox.revision
      render json: { cursor: cursor, records: @mailbox.mail_entries.map { |entry| InstantRecord.record_payload(entry) } }
    end

    def events
      entries = @mailbox.mail_entries.where("server_version > ?", params[:after].to_i).order(:server_version).limit(200)
      frames = entries.map do |entry|
        "id: #{entry.server_version}\nevent: change\ndata: #{InstantRecord.record_payload(entry).to_json}\n\n"
      end
      render plain: frames.join, content_type: "text/event-stream"
    end

    def mutations
      batch = params.require(:mutations)
      return head :bad_request unless batch.is_a?(Array) && batch.all? { |item| item.is_a?(ActionController::Parameters) && item[:changes].is_a?(ActionController::Parameters) }

      # Offline creates can share a timestamp. Parents must exist before their replies.
      messages, actions = batch.partition { |item| item.dig(:changes, :kind) == "message" }
      render json: { results: (messages + actions).map { |mutation| apply(mutation) } }
    end

    private

    def load_mailbox
      @member = params[:member]
      unless MailDirectory.inboxes(@member).include?(params[:inbox])
        return head :forbidden
      end
      @mailbox = Mailbox.open_demo(params[:inbox])
    end

    def apply(mutation)
      changes = mutation.fetch(:changes, {})
      unless mutation[:operation] == "create" && mutation[:record_type] == "MailEntry" &&
          changes[:mailbox_id] == @mailbox.id && changes[:author] == @member &&
          mutation[:record_id].to_s.match?(/\A[\w-]{1,80}\z/)
        raise ArgumentError, "Invalid mailbox write"
      end
      fields = changes.permit(:kind, :parent_id, :address, :subject, :body)
      entry = @mailbox.append!(id: mutation[:record_id], author: @member, attributes: fields.to_h)
      { mutation_id: mutation[:id], status: "applied", version: entry.server_version }
    rescue ArgumentError, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
      { mutation_id: mutation[:id], status: "rejected", reason: "Message could not be saved in this inbox" }
    end
  end
end
