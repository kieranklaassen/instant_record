module Slack
  class ChannelsController < ApplicationController
    extend InstantRecord::RuntimeScoped

    browser_only do
      skip_forgery_protection   # no session secrets in the local runtime
    end

    server_only do
      before_action { response.set_header("x-instant-record-runtime", "server") }
    end

    def index
      # Land on #general (the first seeded channel) when it exists.
      first_channel = Channel.find_by(id: Slack::Seeds::CHANNELS.first[:id]) || Channel.channels.first
      if first_channel
        redirect_to slack_channel_path(first_channel)
      else
        render :empty
      end
    end

    # Display window per render: the newest WINDOW messages by default; a
    # ?floor keyset (plus optional deepen=1 for one more page) extends the
    # render downward as the visitor scrolls up.
    WINDOW = 50

    # Server-runtime anti-abuse clamp, mirroring the records endpoint's hard
    # max: an unauthenticated crafted floor must not force a full
    # multi-thousand-row render. The browser runtime renders unclamped — its
    # local database only ever holds what was synced or scrolled.
    MAX_RENDER_DEPTH = 200

    def show
      @channel = Channel.find(params[:id])

      # The open thread is URL state (?thread=<message id>), so it needs no
      # client-side bookkeeping, survives a reload, and renders identically in
      # both runtimes. A stale id (reset swept the parent) falls back to the
      # plain conversation instead of 404ing the whole channel.
      @thread_parent = @channel.messages.top_level.find_by(id: params[:thread]) if params[:thread]
      @thread_replies = @thread_parent ? @thread_parent.replies.includes(:chat_user).order(:created_at, :id) : []

      # Thread fragment: just the replies list, for the live-update morph.
      return render partial: "thread_replies", layout: false if params[:fragment] && @thread_parent

      @messages = conversation_window
      @reply_counts = Message.where(parent_message_id: @messages.map(&:id)).group(:parent_message_id).count
      # The browser can't rule out older pages — its database holds only the
      # synced window — so it renders optimistically and the first history
      # probe settles it. The server runtime is authoritative. Decided here
      # rather than in the partial because show.html.erb reserves the slot
      # from it too.
      @has_more = InstantRecord.browser? || older_rows_exist?(@messages.first)

      # Scroll-up fragment fetches need none of the page chrome below.
      return render partial: "messages", layout: false if params[:fragment]

      @channels = Channel.channels
      @channel_counts = Message.top_level.group(:channel_id).count
      @dms = Channel.dms
      @users = ChatUser.order(:name)
      @pending_count = InstantRecord.browser? ? InstantRecord.pending_count : 0
    end

    private

    # Rows from the floor (inclusive) to newest, ascending for display. The
    # newest-first limit means the server clamp drops the floor end, never
    # the live end. Top-level only: replies render in the thread panel, not
    # the conversation. (History pages still sync every row — the gem's keyset
    # pages the whole partition — so replies of old messages land locally too;
    # the scope only decides what this list shows.)
    def conversation_window
      newest_first = @channel.messages.top_level.includes(:chat_user).order(created_at: :desc, id: :desc)

      rows =
        if (floor = resolved_floor)
          at, id = floor
          scope = newest_first.where("created_at > :at OR (created_at = :at AND id >= :id)", at: at, id: id)
          scope = scope.limit(MAX_RENDER_DEPTH) unless InstantRecord.browser?
          scope.to_a
        else
          newest_first.limit(WINDOW).to_a
        end
      rows.reverse
    end

    def resolved_floor
      return nil if params[:floor_created_at].blank? || params[:floor_id].blank?

      at = parse_floor_time(params[:floor_created_at])
      return nil unless at

      floor = [at, params[:floor_id].to_s]
      params[:deepen].present? ? deepened_floor(floor) : floor
    end

    # A crafted floor timestamp falls back to the default window rather than
    # 500ing: Time.zone.parse raises on out-of-range components.
    def parse_floor_time(value)
      Time.zone.parse(value.to_s)
    rescue ArgumentError
      nil
    end

    # One page below the given floor — scroll-up asks for "what I had plus
    # the next page" without knowing the new boundary keyset up front.
    def deepened_floor(floor)
      at, id = floor
      older_than(at, id).limit(WINDOW).pluck(:created_at, :id).last || floor
    end

    def older_rows_exist?(oldest)
      return false unless oldest

      older_than(oldest.created_at, oldest.id).exists?
    end

    # The gem owns this keyset predicate and the records endpoint pages history
    # with it, so borrow it rather than keeping a second copy in sync by hand.
    def older_than(at, id)
      Message.instant_record_sync_window.keyset_below(at: at, id: id, partition: @channel.id)
    end
  end
end
