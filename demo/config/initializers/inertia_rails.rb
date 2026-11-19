# Only the Inbox demo is an Inertia page (app/frontend). Inertia 3 reads its
# first page from a script element.
InertiaRails.configure do |config|
  config.use_script_element_for_initial_page = true
  config.always_include_errors_hash = true
end

# Inertia 3 keeps props live: a page object names, under `liveProps`, the
# events each prop listens for. inertia_rails 3.23 has no word for that yet, so
# a controller that defines `inertia_live_props` has them added to its page.
module InertiaLiveProps
  private

  def build_page
    page = super
    return page unless @controller.respond_to?(:inertia_live_props, true)

    page.merge(liveProps: @controller.send(:inertia_live_props))
  end
end

InertiaRails::Renderer.prepend(InertiaLiveProps)
