module InstantRecord
  module Client
    module Notifier
      class Worker
        def records_changed
          File.write("/host/notify", "records_changed")
        end
      end
    end
  end
end
