require "test_helper"
require "rails/generators/test_case"
require "generators/instant_record/ios/ios_generator"

class IosGeneratorTest < Rails::Generators::TestCase
  tests InstantRecord::Generators::IosGenerator
  destination File.expand_path("../../tmp/generators/ios", __dir__)
  setup :prepare_destination

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
