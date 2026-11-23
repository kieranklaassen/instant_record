module InstantRecord
  module Client
    module Notifier
      class Worker
        def records_changed
          # The notice, then one compact JSON delta line per changed record
          # when the client can list them (Client.changes_notice).
          InstantRecord::Host.write_channel("notify", InstantRecord::Client.changes_notice)
        end

        def events_emitted(payload)
          return unless File.directory?("/host")

          File.write("/host/events", payload)
        end
      end
    end
  end
end
