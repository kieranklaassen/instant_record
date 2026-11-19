require "rails/generators"
require "instant_record/native/xcode_project"

module InstantRecord
  module Generators
    # Writes an iPhone app for this Rails app's screens (app/screens):
    #
    #   bin/rails generate instant_record:ios Shop --screen catalog
    #
    # The app is a thin Xcode project in native/ios/<Name>. It links the
    # libraries `bin/rails instant_record:native[iphonesimulator]` builds and
    # the renderer package that ships with the gem.
    class IosGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      argument :app_name, type: :string, banner: "Name"
      class_option :screen, type: :string, required: true, desc: "The first screen, as app/screens names it (catalog for CatalogScreen)"
      class_option :server, type: :string, default: "http://localhost:3000", desc: "Where the Rails app answers"
      class_option :bundle_id, type: :string, desc: "The app's bundle identifier (com.example.<Name>)"

      def check_name
        raise Thor::Error, "Name the app with letters and digits, starting with a capital: Shop" unless app_name.match?(/\A[A-Z][A-Za-z0-9]*\z/)
      end

      def write_app
        template "App.swift.tt", "#{folder}/#{app_name}/#{app_name}App.swift"
        copy_file "LibraryEngine.swift", "#{folder}/#{app_name}/LibraryEngine.swift"
        copy_file "Info.plist", "#{folder}/#{app_name}/Info.plist"
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
          Build the libraries, then the app:

            bin/rails "instant_record:native[iphonesimulator]"
            xcodebuild -project #{folder}/#{app_name}.xcodeproj -scheme #{app_name} -destination 'platform=iOS Simulator,name=iPhone 17' build

          See the gem's native/ios/README.md.
        MSG
      end

      private

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
          headers: from.(gem_root.join("compiled/pipeline/native")),
          libraries: from.(Pathname(destination_root).realpath.join("tmp/instant_record/compiled/.build-native"))
        )
      end
    end
  end
end
