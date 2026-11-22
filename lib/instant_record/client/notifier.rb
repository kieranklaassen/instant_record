module InstantRecord
  module Client
    module Notifier
      class Worker
        def records_changed
          # The notice, then one "Type:id" line for each record that changed
          # when the client can list them (Client.changes_notice).
          File.write("/host/notify", InstantRecord::Client.changes_notice)
        end

        def events_emitted(payload)
          return unless File.directory?("/host")

          File.write("/host/events", payload)
        end
      end
    end
  end
end
