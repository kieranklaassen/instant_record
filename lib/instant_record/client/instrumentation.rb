require "active_support/notifications"
require "json"

module InstantRecord
  module Client
    # Turns the gem's ActiveSupport::Notifications events into sync-inspector
    # entries and hands them to the service worker's report pipe
    # (self.instantRecordReport in the worker template).
    #
    # This is the "sync logic belongs in Ruby" rule applied to observability:
    # the worker used to author narration by inference — it saw a POST return
    # 200 and wrote prose about it. Ruby is the side that knows a pass drained
    # three mutations and the server rejected one for a too-long body, so Ruby
    # authors the entry; JS keeps what is genuinely its own — the transport
    # pipe, the backlog, the scheduler's voice, and the display.
    #
    # Attached from InstantRecord.start in the browser runtime only. Absent a
    # worker hook (an older template), entries drop silently: narration must
    # never break sync, so every JS-facing failure here is swallowed.
    module Instrumentation
      EVENTS = /\.instant_record\z/

      class << self
        def attach
          return if @attached
          @attached = true

          ActiveSupport::Notifications.subscribe(EVENTS) do |name, started, finished, _id, payload|
            ms = ((finished - started) * 1000).round
            entry = entry_for(name.delete_suffix(".instant_record"), payload, ms)
            deliver(entry) if entry
          end
        end

        private

        # One inspector entry per event, in the entry shape the inspector
        # already renders (kind + path + status + ms) — the UI needs no change
        # to display Ruby-authored rows. Quiet outcomes return nil: an empty
        # poll is not news.
        def entry_for(event, payload, ms)
          case event
          when "bootstrap"
            { kind: "sync", path: "bootstrap: #{payload[:records]} records", ms: ms }
          when "drain"
            path = +"drained #{payload[:posted]}"
            if payload[:rejected].to_i.positive?
              path << ", #{payload[:rejected]} rejected: #{Array(payload[:reasons]).join("; ")}"
            end
            { kind: "sync-pass", path: path, ms: ms }
          when "poll", "stream"
            applied = payload[:applied].to_i
            return nil unless applied.positive?
            { kind: "change", path: "applied #{applied} remote change#{"s" unless applied == 1}" }
          when "fetch_history"
            { kind: "history", path: "history page: #{payload[:applied]} rows#{" (beginning)" unless payload[:has_more]}", ms: ms }
          when "offline"
            { kind: "sync", path: "#{payload[:phase]} — offline", status: "offline" }
          end
        end

        def deliver(entry)
          require "js"
          return unless JS.global[:instantRecordReport].typeof.to_s == "function"

          JS.global.call(:instantRecordReport, JSON.generate(entry))
        rescue StandardError, LoadError
          nil
        end
      end
    end
  end
end
