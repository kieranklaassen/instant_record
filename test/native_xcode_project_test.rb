require "test_helper"
require "tmpdir"
require "instant_record/native/xcode_project"

class NativeXcodeProjectTest < ActiveSupport::TestCase
  INBOX = File.expand_path("../native/ios/Inbox", __dir__)

  test "the Inbox's project is what the generator writes for the files in its folder" do
    project = InstantRecord::Native::XcodeProject.new(folder: INBOX, name: "Inbox", bundle_id: "dev.instantrecord.Inbox",
      package: "../InstantRecordNative", headers: "../../../compiled/pipeline/native", libraries: "../../../compiled/.build-native",
      packages: { "Feedback" => "../../../../swift-libraries/feedback" })

    assert_equal File.read(File.join(INBOX, "Inbox.xcodeproj/project.pbxproj")), project.pbxproj, "run ruby native/ios/Inbox/project.rb"
    assert_equal File.read(File.join(INBOX, "Inbox.xcodeproj/xcshareddata/xcschemes/Inbox.xcscheme")), project.scheme
    assert_equal %w[ConversationView.swift InboxApp.swift InboxSummary.swift LibraryEngine.swift], project.sources
  end

  test "the Inbox's engine wrapper is the one the generator gives a new app" do
    assert_equal File.read(File.expand_path("../lib/generators/instant_record/ios/templates/LibraryEngine.swift", __dir__)),
      File.read(File.join(INBOX, "Inbox/LibraryEngine.swift"))
  end

  test "a Swift file added to the app's folder is in the project the next time it is written" do
    Dir.mktmpdir do |folder|
      FileUtils.mkdir_p(File.join(folder, "Shop"))
      File.write(File.join(folder, "Shop/ShopApp.swift"), "")
      project = InstantRecord::Native::XcodeProject.new(folder: folder, name: "Shop", bundle_id: "com.example.Shop", package: "../pkg", headers: "../h", libraries: "../lib")
      before = project.pbxproj

      File.write(File.join(folder, "Shop/CartView.swift"), "")
      File.write(File.join(folder, "Shop/notes.txt"), "")

      assert_not_includes before, "CartView.swift"
      assert_includes project.pbxproj, "path = CartView.swift;"
      assert_includes project.pbxproj, "/* CartView.swift in Sources */,"
      assert_not_includes project.pbxproj, "notes.txt"
      assert_empty project.ui_tests
    end
  end

  test "another package the app links is referenced by its path and linked by its product" do
    Dir.mktmpdir do |folder|
      FileUtils.mkdir_p(File.join(folder, "Shop"))
      File.write(File.join(folder, "Shop/ShopApp.swift"), "")
      pbxproj = InstantRecord::Native::XcodeProject.new(folder: folder, name: "Shop", bundle_id: "com.example.Shop", package: "../pkg", headers: "../h", libraries: "../lib",
        packages: { "Feedback" => "../../feedback" }).pbxproj

      assert_includes pbxproj, "relativePath = ../pkg;"
      assert_includes pbxproj, "relativePath = ../../feedback;"
      assert_includes pbxproj, "productName = Feedback;"
      assert_includes pbxproj, "/* Feedback in Frameworks */,"
      assert_equal pbxproj.scan(/^\t\t(1D\h{22}) /).flatten.size, pbxproj.scan(/^\t\t(1D\h{22}) /).flatten.uniq.size, "two objects share an id"
    end
  end

  test "it writes a project and a shared scheme that name the app, its bundle and where its parts are" do
    Dir.mktmpdir do |folder|
      FileUtils.mkdir_p(File.join(folder, "Shop"))
      File.write(File.join(folder, "Shop/ShopApp.swift"), "")

      written = InstantRecord::Native::XcodeProject.new(folder: folder, name: "Shop", bundle_id: "com.example.Shop", package: "../pkg", headers: "../h", libraries: "../lib").write
      pbxproj = written.join("project.pbxproj").read

      assert_includes pbxproj, %(PRODUCT_BUNDLE_IDENTIFIER = "com.example.Shop";)
      assert_includes pbxproj, %(HEADER_SEARCH_PATHS = "$(SRCROOT)/../h";)
      assert_includes pbxproj, %(LIBRARY_SEARCH_PATHS = "$(SRCROOT)/../lib/$(PLATFORM_NAME)";)
      assert_includes pbxproj, "relativePath = ../pkg;"
      assert_includes written.join("xcshareddata/xcschemes/Shop.xcscheme").read, %(BuildableName = "Shop.app")
      assert_equal pbxproj.scan(/^\t\t(1D\h{22}) /).flatten.size, pbxproj.scan(/^\t\t(1D\h{22}) /).flatten.uniq.size, "two objects share an id"
    end
  end
end
