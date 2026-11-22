module InstantRecord
  module Client
    module Notifier
      class Worker
        def records_changed
          # The notice, then one "Type:id" line for each record that changed
          # when the client can list them (Client.changes_notice).
          InstantRecord::Host.write_channel("notify", InstantRecord::Client.changes_notice)
        end
      end
    end
  end
end
