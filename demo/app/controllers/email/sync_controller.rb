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
      page = message_page
      render json: { cursor: cursor, records: payloads(page) }
    end

    def records
      if params[:thread].present?
        entry = @mailbox.mail_entries.find_by(id: params[:thread], kind: "message")
        return render json: { records: payloads(Array.wrap(entry)), has_more: false }
      end
      return head :bad_request unless params[:type] == "MailEntry" && params[:before_id].present?
      at = Time.iso8601(params[:before_created_at].to_s)
      page = message_page.where("created_at < :at OR (created_at = :at AND id < :id)", at: at, id: params[:before_id])
      rows = page.limit(MailEntry::PAGE_SIZE + 1).to_a
      render json: { records: payloads(rows.first(MailEntry::PAGE_SIZE)), has_more: rows.size > MailEntry::PAGE_SIZE }
    rescue ArgumentError
      head :bad_request
    end

    def incoming
      entry = @mailbox.generate_incoming!
      render json: { id: entry.id }, status: :created
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

    def message_page
      @mailbox.mail_entries.open_messages.order(created_at: :desc, id: :desc).limit(MailEntry::PAGE_SIZE)
    end

    def payloads(page)
      messages = page.to_a
      actions = @mailbox.mail_entries.where(parent_id: messages.map(&:id), kind: MailEntry::ACTIONS).order(:server_version)
      (messages + actions).map { |entry| InstantRecord.record_payload(entry) }
    end

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
