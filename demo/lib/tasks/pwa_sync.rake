# The gem's generator templates are the single source of truth for the PWA
# service worker; the demo consumes a copy. Keeps the two from drifting.
namespace :pwa do
  desc "Copy the gem's PWA service worker template into demo/pwa"
  task :sync do
    template = File.expand_path(
      "../../../lib/generators/instant_record/install/templates/rails.sw.js", __dir__
    )
    copy = Rails.root.join("pwa/rails.sw.js")

    # The stamped digest is the one difference that is supposed to exist, so
    # compare with it normalised back to the placeholder. Anything left over is
    # an edit made to the copy, and copying over it is how worker changes have
    # silently disappeared before. The template is where such an edit belongs,
    # so say so instead of destroying it.
    if File.exist?(copy) && !ENV["FORCE"]
      current = File.read(copy).sub(
        /const BUILD_VERSION = "[0-9a-f]{12}";/,
        %(const BUILD_VERSION = "__INSTANT_RECORD_BUILD_VERSION__";)
      )

      if current != File.read(template)
        abort <<~MSG
          pwa/rails.sw.js differs from the gem template beyond its stamped build version.

            diff #{template} #{copy}

          Port the local edits into the template first (it is the single source of
          truth), or run `rake pwa:sync FORCE=1` to discard them.
        MSG
      end
    end

    FileUtils.cp(template, copy)
    puts "pwa/rails.sw.js <- #{template}"
  end
end
