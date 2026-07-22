# The gem's generator templates are the single source of truth for the PWA
# service worker; the demo consumes a copy. Keeps the two from drifting.
namespace :pwa do
  desc "Copy the gem's PWA service worker template into demo/pwa"
  task :sync do
    template = File.expand_path(
      "../../../lib/generators/instant_record/install/templates/rails.sw.js", __dir__
    )
    FileUtils.cp(template, Rails.root.join("pwa/rails.sw.js"))
    puts "pwa/rails.sw.js <- #{template}"
  end
end
