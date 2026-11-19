# Only the Inbox demo is an Inertia page (app/frontend). Inertia 3 reads its
# first page from a script element.
InertiaRails.configure do |config|
  config.use_script_element_for_initial_page = true
  config.always_include_errors_hash = true
end
