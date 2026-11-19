module Email
  class MailboxesController < ApplicationController
    extend InstantRecord::RuntimeScoped
    browser_only do
      skip_forgery_protection
    end

    # How Inertia keeps the page current. Each prop listens for the one event
    # InstantRecord has: something in the local database changed. Inertia then
    # reloads that prop alone (app/frontend/instant_record/live.js).
    CHANGED = { listeners: [{ channel: { name: "instant_record", type: "local" }, events: ["changed"] }], throttle: 150 }.freeze
    LIVE_PROPS = { mail: CHANGED, thread: CHANGED }.freeze

    # An Inertia page. Its props are the first paint, and every later read is
    # a partial reload of `mail` or `thread`: in the compiled runtime this
    # same action answers it from the local database, with no request to Rails.
    def index
      load_inbox
      return head :forbidden unless @inboxes.include?(@inbox)

      prepare_inbox
      render_page
    end

    def create
      load_inbox
      return head :forbidden unless @inboxes.include?(@inbox)

      kind = params[:kind].to_s
      parent = params[:parent_id].to_s
      subject = params[:subject].to_s.strip
      body = params[:body].to_s.strip
      @address = params[:address].to_s.strip
      return head :unprocessable_entity unless kind == "message" || MailEntry::ACTIONS.include?(kind)
      if kind == "message"
        return head :unprocessable_entity if @address.blank? || @address.length > 254 || subject.blank? || body.blank?
      else
        return head :unprocessable_entity unless MailEntry.find_by(id: parent, mailbox_id: @inbox, kind: "message")
        return head :unprocessable_entity if kind == "reply" && body.blank?
      end

      entry = append_entry(kind, parent, subject, body)
      target = "/email?member=#{@member}&inbox=#{@inbox}"
      target += "&thread=#{entry.id}" if kind == "message"
      target += "&thread=#{parent}" if kind == "reply" || kind == "read"
      finish_write(target)
    end

    private

    def load_inbox
      @member = params[:member].presence || "maya"
      @inbox = params[:inbox].presence || "support"
      @inboxes = MailDirectory.inboxes(@member)
    end

    # A row is a list of strings, in the order app/frontend/lib/mail.js names
    # them: plain enough for the compiled runtime to serialize.
    def mail_row(entry, unread)
      [entry.id, entry.author, entry.address.to_s, entry.subject.to_s, entry.body.to_s, entry.created_at.utc.iso8601(6),
        unread ? "1" : "", MailDirectory.inboxes(entry.author).empty? ? "1" : ""]
    end

    # The newest open conversations. The reader widens `limit` as they scroll,
    # so the list is one query however far down they are.
    def mail_props
      limit = [params[:limit].to_i, MailEntry::PAGE_SIZE].max
      limit = [limit, MailEntry::LIVE_LIMIT].min
      messages = MailEntry.open_messages.where(mailbox_id: @inbox)
      entries = messages.order(created_at: :desc, id: :desc).limit(limit + 1).to_a
      more = entries.size > limit
      entries.pop if more
      unread = messages.where(MailEntry::UNREAD, member: @member)
      marked = {}
      if entries.any?
        shown = unread.where("created_at >= :oldest AND created_at <= :newest", oldest: entries.last.created_at, newest: entries.first.created_at)
        shown.each { |message| marked[message.id] = true }
      end
      rows = []
      entries.each { |entry| rows << mail_row(entry, marked.key?(entry.id)) }
      # `more` speaks for this database alone. Beside a local one the page
      # also asks the sync server for older mail as the reader nears the end.
      { rows: rows, unread_count: unread.count, more: more, limit: limit }
    end

    # The conversation the address names, or the newest one.
    def thread_props
      id = params[:thread].to_s
      if id.empty?
        newest = MailEntry.open_messages.where(mailbox_id: @inbox).order(created_at: :desc, id: :desc).first
        id = newest.id if newest
      end
      message = MailEntry.find_by(id: id, mailbox_id: @inbox, kind: "message") unless id.empty?
      return { id: "", message: [], replies: [], archived: false } unless message

      replies = []
      MailEntry.where(mailbox_id: @inbox, kind: "reply", parent_id: message.id).order(:created_at).each do |reply|
        replies << [reply.id, reply.author, reply.body.to_s, reply.created_at.utc.iso8601(6)]
      end
      unread = MailEntry.where(mailbox_id: @inbox, id: message.id).where(MailEntry::UNREAD, member: @member).exists?
      archived = MailEntry.exists?(mailbox_id: @inbox, kind: "archive", parent_id: message.id)
      { id: message.id, message: mail_row(message, unread), replies: replies, archived: archived }
    end

    def people
      list = []
      ["maya", "theo", "jo"].each { |person| list << [person, MailDirectory.inboxes(person).first] }
      list
    end

    server_only do
      rescue_from ArgumentError, ActiveRecord::RecordInvalid do
        head :unprocessable_entity
      end

      def prepare_inbox
        Mailbox.open_demo(@inbox)
      end

      # Lazy props: a partial reload evaluates only the ones it asks for.
      def render_page
        render inertia: "Email/Inbox", props: {
          member: @member, inbox: @inbox, inboxes: @inboxes, people: people, composing: params[:compose] == "1",
          mail: -> { mail_props }, thread: -> { thread_props }
        }
      end

      # Read by the renderer (config/initializers/inertia_rails.rb).
      def inertia_live_props
        LIVE_PROPS
      end

      # A write returns the reader to the page they were on, with fresh props.
      def finish_write(target)
        redirect_back_or_to target, status: :see_other
      end

      def append_entry(kind, parent, subject, body)
        Mailbox.open_demo(@inbox).append!(id: SecureRandom.uuid, author: @member,
          attributes: { kind: kind, parent_id: parent, address: @address, subject: subject, body: body })
      end
    end

    browser_only do
      def prepare_inbox
      end

      # The compiled runtime has no Inertia gem and its requests carry no
      # headers, so this speaks the protocol itself. A visit arrives with
      # _inertia=1 and the props it wants in _only
      # (app/frontend/instant_record/http.js) and is answered with the page
      # object; a first load gets the same object placed by index.html.erb.
      def render_page
        only = params[:_only].to_s
        props = { member: @member, inbox: @inbox, inboxes: @inboxes, people: people, composing: params[:compose] == "1" }
        props[:mail] = mail_props if only.empty? || only.include?("mail")
        props[:thread] = thread_props if only.empty? || only.include?("thread")
        url = "/email?member=#{@member}&inbox=#{@inbox}"
        url += "&thread=#{params[:thread]}" unless params[:thread].to_s.empty?
        url += "&limit=#{params[:limit].to_i}" if params[:limit].to_i > MailEntry::PAGE_SIZE
        url += "&compose=1" if params[:compose] == "1"
        page = JSON.generate({ component: "Email/Inbox", props: props, url: url, version: "", liveProps: LIVE_PROPS })
        if params[:_inertia] == "1"
          render plain: page, content_type: "application/json"
        else
          @page = page.gsub("<", "\\u003c")
        end
      end

      def finish_write(target)
        redirect_to target, status: :see_other
      end

      def append_entry(kind, parent, subject, body)
        MailEntry.create!(mailbox_id: @inbox, author: @member, kind: kind, parent_id: parent, address: @address, subject: subject, body: body)
      end
    end
  end
end
