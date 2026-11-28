module InstantRecord
  # The app's tabs, routes and tint, from config/native.yml. The app reads it
  # at launch and when it comes to the front, so a deploy changes them.
  class NativeConfigController < ActionController::API
    def show
      config = NativeConfig.load
      return head(:not_found) unless config

      response.headers["Cache-Control"] = "no-cache"
      render json: config
    end
  end
end
