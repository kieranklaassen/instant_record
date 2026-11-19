module Email
  class SyncController < ActionController::API
    before_action do
      headers.merge!(InstantRecord::CORS_HEADERS)
      headers["Cache-Control"] = "no-store"
    end
    before_action :check_token, except: :preflight
    before_action :load_mailbox, except: :preflight

    def preflight
      head :no_content
    end

    def bootstrap
      render json: @mailbox.first_sync
    end

    # Where a new browser may fetch this inbox's shell, when one stands that
    # its build can open and that is not too far behind. No content sends the
    # browser to the bootstrap above. A missing or ageing shell is rebuilt for
    # whoever comes next.
    def shell
      shell = MailShell.latest(@mailbox.id)
      ShellBuildJob.perform_later(@mailbox.id) if shell.nil? || shell.stale?(@mailbox.revision)
      return head :no_content unless shell&.servable?(@mailbox.revision) && params[:fingerprint] == MailShell.fingerprint

      render json: { cursor: shell.cursor, bytes: shell.bytes, built_at: shell.built_at.utc.iso8601,
        path: "/shell/file?#{{ token: shell.signed_token(@member) }.to_query}" }
    end

    def shell_file
      shell = MailShell.find_signed(params[:token].to_s, member: @member, inbox: @mailbox.id)
      return head :not_found unless shell

      send_file shell.path, type: "application/vnd.sqlite3", disposition: "inline"
    end

    # Older mail than the browser holds, a page at a time: the page below a
    # row, or with `search` the conversations that match it. Either way the
    # answer is records, and the browser's own query shows them once they land.
    def records
      if params[:thread].present?
        entry = @mailbox.mail_entries.find_by(id: params[:thread], kind: "message")
        return render json: { records: payloads(Array.wrap(entry)), has_more: false }
      end
      searching = params[:search].present?
      return head :bad_request unless searching || (params[:type] == "MailEntry" && params[:before_id].present?)
      page = message_page
      page = page.where(MailEntry::MATCHING, q: MailEntry.pattern(params[:search])) if searching
      if params[:before_id].present?
        at = Time.iso8601(params[:before_created_at].to_s)
        page = page.where("created_at < :at OR (created_at = :at AND id < :id)", at: at, id: params[:before_id])
      end
      # The background fill asks for bigger pages than a reader's scroll does.
      size = params[:limit].to_i.clamp(MailEntry::PAGE_SIZE, MailEntry::FILL_PAGE_SIZE)
      rows = page.limit(size + 1).to_a
      render json: { records: payloads(rows.first(size)), has_more: rows.size > size }
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

    # A client that says who it is must be who the address says. One that
    # does not is served as before, unless this server requires a token.
    def check_token
      sent = request.authorization.to_s[/\ABearer (.+)\z/, 1]
      return head :unauthorized if sent.nil? && (request.authorization.present? || ENV["INBOX_REQUIRE_TOKEN"].present?)
      head :unauthorized if sent && MailDirectory.member_for(sent) != params[:member]
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
