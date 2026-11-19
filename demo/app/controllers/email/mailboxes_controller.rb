module Email
  class MailboxesController < ApplicationController
    extend InstantRecord::RuntimeScoped
    browser_only do
      skip_forgery_protection
    end

    def index
      load_inbox
      return head :forbidden unless @inboxes.include?(@inbox)

      prepare_inbox
      entries = MailEntry.where(mailbox_id: @inbox)
      messages = MailEntry.open_messages.where(mailbox_id: @inbox)
      @before_id = params[:before].to_s
      @before_at = params[:at].to_s
      @limit = [params[:limit].to_i, MailEntry::PAGE_SIZE].max
      @limit = [@limit, MailEntry::PAGE_SIZE * 3].min
      if params[:after].present?
        boundary = entries.find_by(id: params[:after])
        return head :not_found unless boundary
        newer = messages.where("created_at > :at OR (created_at = :at AND id > :id)", at: boundary.created_at, id: boundary.id)
        rows = newer.order(:created_at, :id).limit(MailEntry::PAGE_SIZE + 1).to_a
        preceding = rows.pop if rows.size > MailEntry::PAGE_SIZE
        @before_id = preceding&.id.to_s
        @before_at = preceding ? preceding.created_at.utc.iso8601(6) : ""
        @mail_entries = rows.reverse
      else
        page = messages.order(created_at: :desc, id: :desc)
        boundary = entries.find_by(id: @before_id) unless @before_id.empty?
        if boundary
          page = page.where("created_at < :at OR (created_at = :at AND id < :id)", at: boundary.created_at, id: boundary.id)
        end
        @mail_entries = page.limit(@limit).to_a
      end
      @composing = params[:compose] == "1"
      @detail = @composing || !params[:thread].to_s.empty?
      unless @composing
        @selected = messages.find_by(id: params[:thread]) || @mail_entries.first
      end
      @replies = entries.where(kind: "reply", parent_id: @selected&.id).order(:created_at).to_a
      unread = messages.where(MailEntry::UNREAD, member: @member)
      @unread_count = unread.count
      @unread = []
      if @mail_entries.any?
        shown = unread.where("created_at >= :oldest AND created_at <= :newest", oldest: @mail_entries.last.created_at, newest: @mail_entries.first.created_at)
        shown.each { |message| @unread << message.id }
      end
      @unread << @selected.id if @selected && !@unread.include?(@selected.id) && unread.exists?(id: @selected.id)
      # Opening a conversation reads it. Background refreshes and the default
      # first row do not, so a row marked unread stays unread until clicked.
      if @selected && params[:fragment].to_s.empty? && params[:thread].to_s == @selected.id && @unread.include?(@selected.id)
        @address = ""
        append_entry("read", @selected.id, "", "")
        @unread.delete(@selected.id)
        @unread_count -= 1
      end
      render partial: "mail", layout: false if params[:fragment]
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
      redirect_to target, status: :see_other
    end

    private

    def load_inbox
      @member = params[:member].presence || "maya"
      @inbox = params[:inbox].presence || "support"
      @inboxes = MailDirectory.inboxes(@member)
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
