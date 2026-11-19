module InstantRecord
  # A native app's screens, asked of this server while developing: the phone
  # sends what it would send its compiled library and gets the same JSON back,
  # so editing a screen's Ruby shows after a pull with no rebuild
  # (HTTPEngine in native/ios).
  #
  # A screen's actions write as whoever its params name, with no session or
  # token consulted. So this answers only when the app turned it on
  # (config.instant_record.native_dev), in a local environment, to a request
  # from this machine, and it sends no CORS headers: a web page cannot drive it.
  class NativeScreensController < ActionController::API
    before_action :local_development_only

    def show
      with_screen { |screen| render json: screen.json }
    end

    def perform
      with_screen do |screen|
        screen.perform(input["action"].to_s, strings(input["with"]))
        head :no_content
      end
    end

    private

    def local_development_only
      head :not_found unless Rails.application.config.instant_record.native_dev && Rails.env.local? && request.local?
    end

    def input
      @input ||= JSON.parse(request.raw_post)
    rescue JSON::ParserError
      @input = {}
    end

    # Looked up by constant each time, so that a screen edited since the
    # last request is the one that answers.
    def with_screen
      folder = Rails.root.join("app/screens").to_s
      Rails.autoloaders.main.eager_load_dir(folder) if File.directory?(folder)
      name = input["screen"].to_s
      found = Native.screens.map(&:name).uniq.find { |class_name| Native.name_of(class_name) == name }&.safe_constantize
      return render(plain: "No screen named #{name}", status: :not_found) unless found

      yield found.new(strings(input["params"]))
    end

    def strings(object)
      (object.is_a?(Hash) ? object : {}).to_h { |name, value| [name.to_s, value.to_s] }
    end
  end
end
