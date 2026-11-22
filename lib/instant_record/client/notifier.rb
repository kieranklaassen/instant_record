module InstantRecord
  module Client
    module Notifier
      class Worker
        def records_changed
          # The notice, then one compact JSON delta line per changed record
          # when the client can list them (Client.changes_notice).
          File.write("/host/notify", InstantRecord::Client.changes_notice)
        end
      end
    end
  end
end
