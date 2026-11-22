module Email
  # Serves prebuilt SQLite shell snapshots for cold-start Inbox loads.
  # Sync itself runs through InstantRecord::Engine.
  class ShellsController < ActionController::API
    before_action do
      headers.merge!(InstantRecord::CORS_HEADERS)
      headers["Cache-Control"] = "no-store"
    end
    before_action :load_mailbox

    def show
      shell = MailShell.latest(@mailbox.id)
      head_cursor = InstantRecord::Change.maximum(:id) || 0
      ShellBuildJob.perform_later(@mailbox.id) if shell.nil? || shell.stale?(head_cursor)
      return head :no_content unless shell&.servable?(head_cursor) && params[:fingerprint] == MailShell.fingerprint

      fill = [MailEntry.instant_record_sync_shape.fill_descriptor(partition: @mailbox.id)].compact
      render json: {
        cursor: shell.cursor,
        bytes: shell.bytes,
        built_at: shell.built_at.utc.iso8601,
        path: "/email/shell/file?#{{ member: @member, inbox: @mailbox.id, token: shell.signed_token(@member) }.to_query}",
        fill: fill
      }
    end

    def file
      shell = MailShell.find_signed(params[:token].to_s, member: @member, inbox: @mailbox.id)
      return head :not_found unless shell

      send_file shell.path, type: "application/vnd.sqlite3", disposition: "inline"
    end

    private

    def load_mailbox
      @member = request.headers["X-Instant-Record-Member"].presence || params[:member].to_s
      inbox = params[:inbox].presence || MailEntry.instant_record_sync_partition.extract(request.headers["X-Instant-Record-Partition"])
      return head :forbidden unless MailDirectory.inboxes(@member).include?(inbox)

      @mailbox = Mailbox.open_demo(inbox)
    end
  end
end
