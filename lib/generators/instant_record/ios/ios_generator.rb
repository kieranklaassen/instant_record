require "rails/generators"
require "instant_record/native/xcode_project"

module InstantRecord
  module Generators
    # Writes an iPhone app for this Rails app's screens (app/screens):
    #
    #   bin/rails generate instant_record:ios Shop --screen catalog
    #
    #   bin/rails generate instant_record:ios Shop --hybrid
    #   bin/rails generate instant_record:ios Shop --hybrid --screen catalog
    #
    # With --hybrid the app's tabs and pages come from Rails, through the
    # ruby_native gem's config and helpers, and a --screen beside it lets
    # Ruby screens be tabs and the places links open.
    #
    # The app is a thin Xcode project in native/ios/<Name>. It links the
    # libraries `bin/rails instant_record:native[iphonesimulator]` builds and
    # the renderer package that ships with the gem.
    class IosGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      argument :app_name, type: :string, banner: "Name"
      class_option :screen, type: :string, desc: "The first screen, as app/screens names it (catalog for CatalogScreen)"
      class_option :hybrid, type: :boolean, default: false, desc: "Tabs and pages that Rails serves, with native bars (the ruby_native gem)"
      class_option :server, type: :string, default: "http://localhost:3000", desc: "Where the Rails app answers"
      class_option :bundle_id, type: :string, desc: "The app's bundle identifier (com.example.<Name>)"

      def check_name
        raise Thor::Error, "Name the app with letters and digits, starting with a capital: Shop" unless app_name.match?(/\A[A-Z][A-Za-z0-9]*\z/)
        raise Thor::Error, "Give --screen NAME for an app of Ruby screens, --hybrid for one of Rails pages, or both" unless compiled? || hybrid?
      end

      # The app's own file is the developer's once written: it holds their
      # views and their token. The rest is written again.
      def write_app
        app = "#{folder}/#{app_name}/#{app_name}App.swift"
        template(hybrid? ? "HybridApp.swift.tt" : "App.swift.tt", app) unless File.exist?(File.join(destination_root, app))
        copy_file "Info.plist", "#{folder}/#{app_name}/Info.plist"
        return unless compiled?

        create_file "#{folder}/#{app_name}/RubyScreens.swift", <<~SWIFT if hybrid?
          /// The Ruby screens a route may open: those in app/screens when the
          /// generator last ran. Written by instant_record:ios.
          let rubyScreens: Set<String> = #{screen_names.inspect}
        SWIFT
        copy_file "LibraryEngine.swift", "#{folder}/#{app_name}/LibraryEngine.swift"
        create_file "#{folder}/#{app_name}/#{app_name}-Bridging-Header.h", %(#include "instant_record_native.h"\n)
      end

      # The project is written from the files now in the folder. Run this
      # generator again, with --force, after adding a Swift file.
      def write_project
        return if options[:pretend]
        create_file "#{folder}/#{app_name}.xcodeproj/project.pbxproj", project.pbxproj
        create_file "#{folder}/#{app_name}.xcodeproj/xcshareddata/xcschemes/#{app_name}.xcscheme", project.scheme
      end

      def show_next_steps
        say <<~MSG
          #{"Add the gem the pages speak through, and list your tabs:\n\n  bundle add ruby_native\n  bin/rails generate ruby_native:install\n" if hybrid?}
          Build the #{"libraries, then the " if compiled?}app:

            #{%(bin/rails "instant_record:native[iphonesimulator]"\n  ) if compiled?}xcodebuild -project #{folder}/#{app_name}.xcodeproj -scheme #{app_name} -destination 'platform=iOS Simulator,name=iPhone 17' build

          See the guides in docs/ios: https://github.com/kieranklaassen/instant_record/tree/main/docs/ios
        MSG
      end

      private

      def hybrid? = options[:hybrid]
      def compiled? = options[:screen].present?

      # The screens a route may open: those in app/screens now.
      def screen_names
        found = Dir[Rails.root.join("app/screens/*_screen.rb")].map { |file| File.basename(file, "_screen.rb") }
        (found | [options[:screen]]).sort
      end

      def folder = "native/ios/#{app_name}"

      def mount_path = Rails.application.config.instant_record.mount_path || InstantRecord::DEFAULT_MOUNT_PATH

      def project
        gem_root = Pathname(__dir__).join("../../../..").realpath
        here = Pathname(destination_root).join(folder)
        FileUtils.mkdir_p(here)
        from = ->(path) { Pathname(path).relative_path_from(here.realpath).to_s }
        InstantRecord::Native::XcodeProject.new(
          folder: here, name: app_name, bundle_id: options[:bundle_id] || "com.example.#{app_name}",
          package: from.(gem_root.join("native/ios/InstantRecordNative")),
          headers: (from.(gem_root.join("compiled/pipeline/native")) if compiled?),
          libraries: (from.(Pathname(destination_root).realpath.join("tmp/instant_record/compiled/.build-native")) if compiled?)
        )
      end
    end
  end
end
