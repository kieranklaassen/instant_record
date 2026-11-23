module Email
  # Demo-only button endpoint ("Generate incoming email"). Creates an external
  # message on the server; InstantRecord::Syncable logs the partitioned change
  # and the core InstantRecord::Engine delivers it to connected clients.
  class IncomingController < ActionController::API
    before_action do
      headers.merge!(InstantRecord::CORS_HEADERS)
      headers["Cache-Control"] = "no-store"
    end

    def preflight
      head :no_content
    end

    def create
      member = request.headers["X-Instant-Record-Member"].presence || params[:member].to_s
      inbox = params[:inbox].presence || extract_partition_inbox
      return head :forbidden unless MailDirectory.inboxes(member).include?(inbox)

      entry = Mailbox.open_demo(inbox).generate_incoming!
      render json: { id: entry.id }, status: :created
    end

    private

    def extract_partition_inbox
      MailEntry.instant_record_sync_partition.extract(request.headers["X-Instant-Record-Partition"])
    end
  end
end
