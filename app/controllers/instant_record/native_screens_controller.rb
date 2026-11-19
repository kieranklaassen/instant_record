module InstantRecord
  # A native app's screens, asked of this server while developing: the phone
  # sends what it would send its compiled library and gets the same JSON back,
  # so editing a screen's Ruby shows after a pull with no rebuild
  # (HTTPEngine in native/ios).
  #
  # A screen's actions write as whoever its params name, with no session or
  # token consulted. So this answers only when the app turned it on
  # (config.instant_record.native_dev), in a local environment, to a request
  # from this machine. It takes JSON alone and sends no CORS headers: a web
  # page cannot drive it.
  class NativeScreensController < ActionController::API
    before_action :local_development_only
    before_action { head :unsupported_media_type unless request.content_mime_type&.json? }

    def show
      with_screen { |screen| render json: screen.json }
    end

    def perform
      with_screen do |screen|
        screen.perform(input["action"].to_s, Native::Screen.strings(input["args"]), Native::Screen.strings(input["values"]))
        head :no_content
      end
    end

    private

    def local_development_only
      head :not_found unless Rails.application.config.instant_record.native_dev && Rails.env.local? && request.local?
    end

    def input
      @input ||= begin
        parsed = JSON.parse(request.raw_post)
        parsed.is_a?(Hash) ? parsed : {}
      rescue JSON::ParserError
        {}
      end
    end

    # Found by constant each time, from the rule that names a screen's file,
    # so that autoloading finds it and a screen edited since the last request
    # is the one that answers.
    def with_screen
      name = input["screen"].to_s
      found = screen_class(name)
      return render(plain: "No screen named #{name}", status: :not_found) unless found

      yield found.new(Native::Screen.strings(input["params"]))
    end

    def screen_class(name)
      found = Native.class_name(name).safe_constantize
      found if found.is_a?(Class) && found < Native::Screen
    rescue ArgumentError
      nil
    end
  end
end
