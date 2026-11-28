require "test_helper"
require "rails/generators/test_case"
require "tmpdir"
require "generators/instant_record/ios/ios_generator"

class IosGeneratorTest < Rails::Generators::TestCase
  tests InstantRecord::Generators::IosGenerator
  # A folder for each test: the suite runs in several processes at once.
  setup { self.destination_root = Dir.mktmpdir("ios-generator") }
  teardown { FileUtils.remove_entry(destination_root) }

  test "writes an app that names its first screen and its server, and a project for it" do
    run_generator %w[Shop --screen catalog --server http://localhost:4000 --bundle-id com.acme.Shop]

    assert_file "native/ios/Shop/Shop/ShopApp.swift" do |app|
      assert_match 'struct ShopApp: App', app
      assert_match 'Route("catalog")', app
      assert_match '?? "http://localhost:4000"', app
      assert_match 'endpoint: server + "/instant_record"', app
    end
    assert_file "native/ios/Shop/Shop/LibraryEngine.swift", /ir_set_exchange/
    assert_file "native/ios/Shop/Shop/Shop-Bridging-Header.h", /instant_record_native.h/
    assert_file "native/ios/Shop/Shop/Info.plist", /NSAllowsLocalNetworking/
    assert_file "native/ios/Shop/Shop.xcodeproj/project.pbxproj" do |project|
      assert_match 'PRODUCT_BUNDLE_IDENTIFIER = "com.acme.Shop";', project
      assert_match "/* ShopApp.swift in Sources */", project
      assert_match "/* LibraryEngine.swift in Sources */", project
      assert_match %r{relativePath = .*native/ios/InstantRecordNative;}, project
      assert_match %r{HEADER_SEARCH_PATHS = "\$\(SRCROOT\)/.*compiled/pipeline/native";}, project
      assert_match %r{LIBRARY_SEARCH_PATHS = "\$\(SRCROOT\)/\.\./\.\./\.\./tmp/instant_record/compiled/\.build-native/\$\(PLATFORM_NAME\)";}, project
    end
    assert_file "native/ios/Shop/Shop.xcodeproj/xcshareddata/xcschemes/Shop.xcscheme", /BlueprintName = "Shop"/
  end

  test "the paths it writes lead to the package and the header" do
    run_generator %w[Shop --screen catalog]
    folder = File.join(destination_root, "native/ios/Shop")
    project = File.read(File.join(folder, "Shop.xcodeproj/project.pbxproj"))

    assert File.file?(File.expand_path(File.join(project[/relativePath = (.+);/, 1], "Package.swift"), folder))
    assert File.file?(File.expand_path(File.join(project[%r{HEADER_SEARCH_PATHS = "\$\(SRCROOT\)/(.+)";}, 1], "instant_record_native.h"), folder))
  end

  test "a hybrid app holds no compiled Ruby" do
    run_generator %w[Shop --hybrid --server http://localhost:4000]

    assert_file "native/ios/Shop/Shop/ShopApp.swift" do |app|
      assert_match "HybridView(host: host)", app
      assert_match '?? "http://localhost:4000"', app
      assert_no_match(/AppHost|LibraryEngine|<%/, app)
    end
    assert_no_file "native/ios/Shop/Shop/LibraryEngine.swift"
    assert_no_file "native/ios/Shop/Shop/Shop-Bridging-Header.h"
    assert_file "native/ios/Shop/Shop.xcodeproj/project.pbxproj" do |project|
      assert_no_match(/Bridging|linstant_record_app|HEADER_SEARCH|LIBRARY_SEARCH/, project)
      assert_match "/* ShopApp.swift in Sources */", project
    end
  end

  test "a hybrid app with a screen holds both, and the screens its routes may open" do
    run_generator %w[Shop --hybrid --screen mailbox]

    assert_file "native/ios/Shop/Shop/ShopApp.swift" do |app|
      assert_match 'Route("mailbox")', app
      assert_match "screens: rubyScreens", app
    end
    assert_file "native/ios/Shop/Shop/RubyScreens.swift", /\[.*"mailbox".*"thread".*\]/
    assert_file "native/ios/Shop/Shop/LibraryEngine.swift"
    assert_file "native/ios/Shop/Shop.xcodeproj/project.pbxproj", /linstant_record_app/
  end

  test "run again with --force, it leaves the app's own file and writes the rest" do
    run_generator %w[Shop --hybrid --screen mailbox]
    File.write(File.join(destination_root, "native/ios/Shop/Shop/ShopApp.swift"), "// mine")
    File.write(File.join(destination_root, "native/ios/Shop/Shop/RubyScreens.swift"), "// old")

    run_generator %w[Shop --hybrid --screen mailbox --force]

    assert_file "native/ios/Shop/Shop/ShopApp.swift", "// mine"
    assert_file "native/ios/Shop/Shop/RubyScreens.swift", /rubyScreens/
  end

  test "an app of neither kind is refused, and nothing is written" do
    output = capture(:stderr) { run_generator %w[Shop] }

    assert_match(/--screen.*--hybrid/, output)
    assert_no_file "native/ios/Shop"
  end

  test "a name that is not a Swift type name is refused, and nothing is written" do
    output = capture(:stderr) { run_generator %w[my-shop --screen catalog] }

    assert_match "Name the app", output
    assert_no_file "native/ios/my-shop"
  end

  test "an app that is already there is not written over" do
    run_generator %w[Shop --screen catalog]
    File.write(File.join(destination_root, "native/ios/Shop/Shop/ShopApp.swift"), "// mine")

    run_generator %w[Shop --screen other --skip]

    assert_file "native/ios/Shop/Shop/ShopApp.swift", "// mine"
  end
end
