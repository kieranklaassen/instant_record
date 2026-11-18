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
      archived = entries.where(kind: "archive").pluck(:parent_id)
      @mail_entries = entries.where(kind: "message").order(created_at: :desc).to_a.reject { |entry| archived.include?(entry.id) }
      @selected = entries.find_by(id: params[:thread], kind: "message") if params[:thread].present?
      @replies = entries.where(kind: "reply", parent_id: params[:thread]).order(:created_at).to_a
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
      return head :unprocessable_entity unless %w[message reply archive].include?(kind)
      if kind == "message"
        return head :unprocessable_entity if @address.blank? || @address.length > 254 || subject.blank? || body.blank?
      else
        return head :unprocessable_entity unless MailEntry.find_by(id: parent, mailbox_id: @inbox, kind: "message")
        return head :unprocessable_entity if kind == "reply" && body.blank?
      end

      entry = append_entry(kind, parent, subject, body)
      target = "/email?member=#{@member}&inbox=#{@inbox}"
      target += "&thread=#{entry.id}" if kind == "message"
      target += "&thread=#{parent}" if kind == "reply"
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
