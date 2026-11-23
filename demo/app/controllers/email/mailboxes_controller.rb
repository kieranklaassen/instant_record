module Email
  class MailboxesController < ApplicationController
    extend InstantRecord::RuntimeScoped
    browser_only do
      skip_forgery_protection
    end

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
      # A search narrows the same list. Beside a local database it answers
      # from what is held, and the page asks the sync server for the rest.
      term = params[:q].to_s.strip
      messages = messages.where(MailEntry::MATCHING, q: MailEntry.pattern(term)) unless term.empty?
      # The conversation the address names is in the list: the window widens
      # to the page that holds it, so a link opens it however deep it lies.
      thread = params[:thread].to_s
      named = MailEntry.find_by(id: thread, mailbox_id: @inbox, kind: "message") unless thread.empty?
      if named
        ahead = messages.where("created_at > :at OR (created_at = :at AND id > :id)", at: named.created_at, id: named.id).count
        held = (ahead / MailEntry::PAGE_SIZE + 1) * MailEntry::PAGE_SIZE
        limit = held if held > limit && held <= MailEntry::LIVE_LIMIT
      end
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
      { rows: rows, unread_count: unread.count, more: more, limit: limit, q: term }
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

    # One rendering path for both Rails and the compiled WASI runtime:
    # InstantRecord::Inertia::Page reads X-Inertia / X-Inertia-Partial-* from
    # request.headers and evaluates `mail` / `thread` only when requested.
    def render_page
      page = InstantRecord::Inertia::Page.for_request("Email/Inbox", request)
      page.string("member", @member)
      page.string("inbox", @inbox)
      page.strings("inboxes", @inboxes)
      page.lazy("people") { JSON.generate(people) }
      page.bool("composing", params[:compose] == "1")
      page.live("mail", "MailEntry") { JSON.generate(mail_props) }
      page.live("thread", "MailEntry") { JSON.generate(thread_props) }

      response.headers["Vary"] = "X-Inertia"
      if page.inertia?
        response.headers["X-Inertia"] = "true"
        render plain: page.json, content_type: "application/json"
      else
        @page = page.json
      end
    end

    # A write returns the reader to the page they were on, with fresh props.
    def finish_write(target)
      redirect_back_or_to target, status: :see_other
    end

    server_only do
      rescue_from ArgumentError, ActiveRecord::RecordInvalid do
        head :unprocessable_entity
      end

      def prepare_inbox
        Mailbox.open_demo(@inbox)
      end

      def append_entry(kind, parent, subject, body)
        Mailbox.open_demo(@inbox).append!(id: SecureRandom.uuid, author: @member,
          attributes: { kind: kind, parent_id: parent, address: @address, subject: subject, body: body })
      end
    end

    browser_only do
      def prepare_inbox
      end

      def append_entry(kind, parent, subject, body)
        MailEntry.create!(mailbox_id: @inbox, author: @member, kind: kind, parent_id: parent, address: @address, subject: subject, body: body)
      end
    end
  end
end
