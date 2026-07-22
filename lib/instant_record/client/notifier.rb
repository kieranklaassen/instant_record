module InstantRecord
  module Client
    module Notifier
      # Tells every open tab that local data changed so pages re-render.
      # Runs in the service worker context; indexes the client list rather
      # than passing Ruby procs to JS (narrower interop surface).
      class JsClients
        def initialize
          require "js"
        end

        def records_changed
          clients = JS.global[:clients].matchAll.await
          message = JS.eval("return {type: 'records_changed'}")

          clients[:length].to_i.times do |i|
            clients[i].postMessage(message)
          end
        end
      end
    end
  end
end
