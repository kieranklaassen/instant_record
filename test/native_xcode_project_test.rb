require "test_helper"
require "digest"
require "tmpdir"
require "instant_record/native/xcode_project"

class NativeXcodeProjectTest < ActiveSupport::TestCase
  INBOX = File.expand_path("../native/ios/Inbox", __dir__)

  test "the Inbox's project is what the generator writes for the files in its folder" do
    project = InstantRecord::Native::XcodeProject.new(folder: INBOX, name: "Inbox", bundle_id: "dev.instantrecord.Inbox",
      package: "../InstantRecordNative", headers: "../../../compiled/pipeline/native", libraries: "../../../compiled/.build-native",
      packages: { "Feedback" => "../../../../swift-libraries/feedback" })

    expected_pbxproj = File.read(File.join(INBOX, "Inbox.xcodeproj/project.pbxproj"))
    expected_scheme = File.read(File.join(INBOX, "Inbox.xcodeproj/xcshareddata/xcschemes/Inbox.xcscheme"))
    actual_pbxproj = project.pbxproj
    actual_scheme = project.scheme

    assert_equal expected_pbxproj, actual_pbxproj, "run ruby native/ios/Inbox/project.rb"
    assert_equal Digest::SHA256.hexdigest(expected_pbxproj), Digest::SHA256.hexdigest(actual_pbxproj)
    assert_equal expected_scheme, actual_scheme
    assert_equal Digest::SHA256.hexdigest(expected_scheme), Digest::SHA256.hexdigest(actual_scheme)
    assert_equal %w[ConversationView.swift InboxApp.swift InboxSummary.swift InstantRecordContracts.swift LibraryEngine.swift], project.sources
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

  test "an app with no libraries links none, and headers and libraries come together" do
    Dir.mktmpdir do |folder|
      FileUtils.mkdir_p(File.join(folder, "Shop"))
      File.write(File.join(folder, "Shop/ShopApp.swift"), "")
      given = { folder: folder, name: "Shop", bundle_id: "com.example.Shop", package: "../pkg" }
      pbxproj = InstantRecord::Native::XcodeProject.new(**given).pbxproj

      assert_no_match(/Bridging|SEARCH_PATHS|OTHER_LDFLAGS/, pbxproj)
      assert_unique_object_ids(pbxproj)
      assert_raises(ArgumentError) { InstantRecord::Native::XcodeProject.new(**given, headers: "../h") }
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

  test "UI test files are rendered into build files, file references, groups, and sources build phase with unique IDs" do
    Dir.mktmpdir do |folder|
      FileUtils.mkdir_p(File.join(folder, "Shop"))
      FileUtils.mkdir_p(File.join(folder, "ShopUITests"))
      File.write(File.join(folder, "Shop/ShopApp.swift"), "")
      File.write(File.join(folder, "ShopUITests/LaunchUITests.swift"), "")
      File.write(File.join(folder, "ShopUITests/CheckoutUITests.swift"), "")
      File.write(File.join(folder, "ShopUITests/README.md"), "")

      project = InstantRecord::Native::XcodeProject.new(folder: folder, name: "Shop", bundle_id: "com.example.Shop", package: "../pkg", headers: "../h", libraries: "../lib")
      pbxproj = project.pbxproj

      assert_equal %w[CheckoutUITests.swift LaunchUITests.swift], project.ui_tests

      build_files = section(pbxproj, "PBXBuildFile")
      file_refs = section(pbxproj, "PBXFileReference")
      groups = section(pbxproj, "PBXGroup")
      sources_phases = section(pbxproj, "PBXSourcesBuildPhase")

      %w[CheckoutUITests.swift LaunchUITests.swift].each do |file|
        assert_includes build_files, "/* #{file} in Sources */ = {isa = PBXBuildFile;"
        assert_includes file_refs, "/* #{file} */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = #{file};"
        assert_includes groups, "/* #{file} */,"
        assert_includes sources_phases, "/* #{file} in Sources */,"
      end
      assert_not_includes pbxproj, "README.md"
      assert_unique_object_ids(pbxproj)
    end
  end

  test "file references quote filenames with special characters and leave simple filenames unquoted" do
    Dir.mktmpdir do |folder|
      FileUtils.mkdir_p(File.join(folder, "My-App"))
      File.write(File.join(folder, "My-App/PlainView.swift"), "")
      File.write(File.join(folder, "My-App/Detail-View.swift"), "")
      File.write(File.join(folder, "My-App/Cart View.swift"), "")

      pbxproj = InstantRecord::Native::XcodeProject.new(folder: folder, name: "My-App", bundle_id: "com.example.MyApp", package: "../pkg", headers: "../h", libraries: "../lib").pbxproj
      file_refs = section(pbxproj, "PBXFileReference")

      assert_includes file_refs, "path = PlainView.swift;"
      assert_includes file_refs, "path = Info.plist;"
      assert_includes file_refs, %(path = "My-App-Bridging-Header.h";)
      assert_includes file_refs, %(path = "Detail-View.swift";)
      assert_includes file_refs, %(path = "Cart View.swift";)
    end
  end

  test "unknown object kind in id raises KeyError rather than TypeError" do
    project = InstantRecord::Native::XcodeProject.new(folder: INBOX, name: "Inbox", bundle_id: "dev.instantrecord.Inbox", package: "../pkg", headers: "../h", libraries: "../lib")

    error = assert_raises(KeyError) { project.send(:id, :nonexistent_kind) }
    assert_includes error.message, ":nonexistent_kind"
  end

  test "non-file .swift directories and non-directory subfolders are ignored" do
    Dir.mktmpdir do |folder|
      FileUtils.mkdir_p(File.join(folder, "Shop/Generated.swift"))
      File.write(File.join(folder, "Shop/App.swift"), "")
      File.write(File.join(folder, "ShopUITests"), "not a directory")

      project = InstantRecord::Native::XcodeProject.new(folder: folder, name: "Shop", bundle_id: "com.example.Shop", package: "../pkg", headers: "../h", libraries: "../lib")

      assert_equal ["App.swift"], project.sources
      assert_empty project.ui_tests
      assert_not_includes project.pbxproj, "Generated.swift"
    end
  end

  test "multiple extra Swift packages retain deterministic ordering and unique IDs" do
    Dir.mktmpdir do |folder|
      FileUtils.mkdir_p(File.join(folder, "Shop"))
      File.write(File.join(folder, "Shop/ShopApp.swift"), "")

      pbxproj = InstantRecord::Native::XcodeProject.new(
        folder: folder, name: "Shop", bundle_id: "com.example.Shop",
        package: "../pkg", headers: "../h", libraries: "../lib",
        packages: { "Feedback" => "../../feedback", "Analytics" => "../../analytics", "Logging" => "../logging" }
      ).pbxproj

      expected_products = %w[InstantRecordNative Feedback Analytics Logging]
      expected_paths = %w[../pkg ../../feedback ../../analytics ../logging]

      assert_equal expected_products, section(pbxproj, "PBXFrameworksBuildPhase").scan(%r{/\* (\S+) in Frameworks \*/}).flatten
      assert_equal expected_products, section(pbxproj, "XCSwiftPackageProductDependency").scan(/productName = (\S+);/).flatten
      assert_equal expected_paths, section(pbxproj, "XCLocalSwiftPackageReference").scan(/relativePath = (\S+);/).flatten
      assert_equal expected_paths, section(pbxproj, "PBXProject").scan(/XCLocalSwiftPackageReference "([^"]+)"/).flatten
      assert_unique_object_ids(pbxproj)
    end
  end

  private

  def section(pbxproj, name)
    pbxproj[%r{/\* Begin #{Regexp.escape(name)} section \*/\n(.*?)\n/\* End #{Regexp.escape(name)} section \*/}m, 1]
  end

  def assert_unique_object_ids(pbxproj)
    ids = pbxproj.scan(/^\t\t(1D\h{22}) /).flatten
    assert_equal ids.size, ids.uniq.size, "two objects share an id"
  end
end
