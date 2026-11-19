require "fileutils"
require "pathname"

module InstantRecord
  module Native
    # Writes the Xcode project for a native app whose screens are Ruby: one
    # app target that links the compiled libraries and the renderer package,
    # and a UI test target when the app has UI tests. The project file is
    # this class's output and is never edited by hand: add a Swift file to
    # the app's folder and write the project again.
    #
    #   InstantRecord::Native::XcodeProject.new(
    #     folder: "native/ios/Inbox", name: "Inbox", bundle_id: "dev.instantrecord.Inbox",
    #     package: "../InstantRecordNative", headers: "../../../compiled/pipeline/native",
    #     libraries: "../../../compiled/.build-native"
    #   ).write
    #
    # `folder` holds `<name>/` with the app's Swift files, and `<name>UITests/`
    # when it has any. `package`, `headers` and `libraries` are paths from
    # `folder`: the InstantRecordNative Swift package, the folder with
    # instant_record_native.h, and the folder whose `iphonesimulator`
    # subfolder holds the built libraries. `packages` are other Swift
    # packages the app links, each product's name with its path from
    # `folder`: `packages: { "Feedback" => "../../feedback" }`.
    class XcodeProject
      def initialize(folder:, name:, bundle_id:, package:, headers:, libraries:, packages: {})
        @folder = Pathname(folder)
        @name = name
        @bundle_id = bundle_id
        @packages = [["InstantRecordNative", package]] + packages.to_a
        @headers = headers
        @libraries = libraries
      end

      def write
        project = @folder.join("#{@name}.xcodeproj")
        FileUtils.mkdir_p(project.join("xcshareddata/xcschemes"))
        project.join("project.pbxproj").write(pbxproj)
        project.join("xcshareddata/xcschemes/#{@name}.xcscheme").write(scheme)
        project
      end

      def sources = swift_files(@name)
      def ui_tests = swift_files("#{@name}UITests")

      def pbxproj
        app, tests = sources, ui_tests
        others = ["#{@name}-Bridging-Header.h", "Info.plist"]
        <<~PBXPROJ
          // !$*UTF8*$!
          {
          	archiveVersion = 1;
          	classes = {
          	};
          	objectVersion = 60;
          	objects = {

          /* Begin PBXBuildFile section */
          #{app.each_with_index.map { |file, n| "\t\t#{id(:build, n)} /* #{file} in Sources */ = {isa = PBXBuildFile; fileRef = #{id(:file, n)} /* #{file} */; };" }.join("\n")}
          #{tests.each_with_index.map { |file, n| "\t\t#{id(:test_build, n)} /* #{file} in Sources */ = {isa = PBXBuildFile; fileRef = #{id(:test_file, n)} /* #{file} */; };" }.join("\n")}
          #{each_package { |product, _, n| "\t\t#{id(:package_build, n)} /* #{product} in Frameworks */ = {isa = PBXBuildFile; productRef = #{id(:package_product, n)} /* #{product} */; };" }}
          /* End PBXBuildFile section */

          /* Begin PBXContainerItemProxy section */
          		#{id(:proxy)} /* PBXContainerItemProxy */ = {
          			isa = PBXContainerItemProxy;
          			containerPortal = #{id(:project)} /* Project object */;
          			proxyType = 1;
          			remoteGlobalIDString = #{id(:app_target)};
          			remoteInfo = #{@name};
          		};
          /* End PBXContainerItemProxy section */

          /* Begin PBXFileReference section */
          #{app.each_with_index.map { |file, n| file_reference(id(:file, n), file, "sourcecode.swift") }.join("\n")}
          #{others.each_with_index.map { |file, n| file_reference(id(:other, n), file, file.end_with?(".h") ? "sourcecode.c.h" : "text.plist.xml") }.join("\n")}
          #{tests.each_with_index.map { |file, n| file_reference(id(:test_file, n), file, "sourcecode.swift") }.join("\n")}
          		#{id(:app_product)} /* #{@name}.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = #{@name}.app; sourceTree = BUILT_PRODUCTS_DIR; };
          		#{id(:test_product)} /* #{@name}UITests.xctest */ = {isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = #{@name}UITests.xctest; sourceTree = BUILT_PRODUCTS_DIR; };
          /* End PBXFileReference section */

          /* Begin PBXFrameworksBuildPhase section */
          		#{id(:frameworks)} /* Frameworks */ = {
          			isa = PBXFrameworksBuildPhase;
          			buildActionMask = 2147483647;
          			files = (
          #{each_package { |product, _, n| "\t\t\t\t#{id(:package_build, n)} /* #{product} in Frameworks */," }}
          			);
          			runOnlyForDeploymentPostprocessing = 0;
          		};
          /* End PBXFrameworksBuildPhase section */

          /* Begin PBXGroup section */
          		#{id(:root_group)} = {
          			isa = PBXGroup;
          			children = (
          				#{id(:app_group)} /* #{@name} */,
          				#{id(:test_group)} /* #{@name}UITests */,
          				#{id(:products_group)} /* Products */,
          			);
          			sourceTree = "<group>";
          		};
          		#{id(:app_group)} /* #{@name} */ = {
          			isa = PBXGroup;
          			children = (
          #{(app.each_index.map { |n| "\t\t\t\t#{id(:file, n)} /* #{app[n]} */," } + others.each_index.map { |n| "\t\t\t\t#{id(:other, n)} /* #{others[n]} */," }).join("\n")}
          			);
          			path = #{@name};
          			sourceTree = "<group>";
          		};
          		#{id(:test_group)} /* #{@name}UITests */ = {
          			isa = PBXGroup;
          			children = (
          #{tests.each_index.map { |n| "\t\t\t\t#{id(:test_file, n)} /* #{tests[n]} */," }.join("\n")}
          			);
          			path = #{@name}UITests;
          			sourceTree = "<group>";
          		};
          		#{id(:products_group)} /* Products */ = {
          			isa = PBXGroup;
          			children = (
          				#{id(:app_product)} /* #{@name}.app */,
          				#{id(:test_product)} /* #{@name}UITests.xctest */,
          			);
          			name = Products;
          			sourceTree = "<group>";
          		};
          /* End PBXGroup section */

          /* Begin PBXNativeTarget section */
          		#{id(:app_target)} /* #{@name} */ = {
          			isa = PBXNativeTarget;
          			buildConfigurationList = #{id(:app_configurations)} /* Build configuration list for PBXNativeTarget "#{@name}" */;
          			buildPhases = (
          				#{id(:app_sources)} /* Sources */,
          				#{id(:frameworks)} /* Frameworks */,
          			);
          			buildRules = (
          			);
          			dependencies = (
          			);
          			name = #{@name};
          			packageProductDependencies = (
          #{each_package { |product, _, n| "\t\t\t\t#{id(:package_product, n)} /* #{product} */," }}
          			);
          			productName = #{@name};
          			productReference = #{id(:app_product)} /* #{@name}.app */;
          			productType = "com.apple.product-type.application";
          		};
          		#{id(:test_target)} /* #{@name}UITests */ = {
          			isa = PBXNativeTarget;
          			buildConfigurationList = #{id(:test_configurations)} /* Build configuration list for PBXNativeTarget "#{@name}UITests" */;
          			buildPhases = (
          				#{id(:test_sources)} /* Sources */,
          			);
          			buildRules = (
          			);
          			dependencies = (
          				#{id(:dependency)} /* PBXTargetDependency */,
          			);
          			name = #{@name}UITests;
          			productName = #{@name}UITests;
          			productReference = #{id(:test_product)} /* #{@name}UITests.xctest */;
          			productType = "com.apple.product-type.bundle.ui-testing";
          		};
          /* End PBXNativeTarget section */

          /* Begin PBXProject section */
          		#{id(:project)} /* Project object */ = {
          			isa = PBXProject;
          			attributes = {
          				BuildIndependentTargetsInParallel = 1;
          				LastUpgradeCheck = 2720;
          			};
          			buildConfigurationList = #{id(:project_configurations)} /* Build configuration list for PBXProject "#{@name}" */;
          			compatibilityVersion = "Xcode 15.0";
          			developmentRegion = en;
          			hasScannedForEncodings = 0;
          			knownRegions = (
          				en,
          				Base,
          			);
          			mainGroup = #{id(:root_group)};
          			packageReferences = (
          #{each_package { |_, path, n| %(\t\t\t\t#{id(:package, n)} /* XCLocalSwiftPackageReference "#{path}" */,) }}
          			);
          			productRefGroup = #{id(:products_group)} /* Products */;
          			projectDirPath = "";
          			projectRoot = "";
          			targets = (
          				#{id(:app_target)} /* #{@name} */,
          				#{id(:test_target)} /* #{@name}UITests */,
          			);
          		};
          /* End PBXProject section */

          /* Begin PBXSourcesBuildPhase section */
          		#{id(:app_sources)} /* Sources */ = {
          			isa = PBXSourcesBuildPhase;
          			buildActionMask = 2147483647;
          			files = (
          #{app.each_index.map { |n| "\t\t\t\t#{id(:build, n)} /* #{app[n]} in Sources */," }.join("\n")}
          			);
          			runOnlyForDeploymentPostprocessing = 0;
          		};
          		#{id(:test_sources)} /* Sources */ = {
          			isa = PBXSourcesBuildPhase;
          			buildActionMask = 2147483647;
          			files = (
          #{tests.each_index.map { |n| "\t\t\t\t#{id(:test_build, n)} /* #{tests[n]} in Sources */," }.join("\n")}
          			);
          			runOnlyForDeploymentPostprocessing = 0;
          		};
          /* End PBXSourcesBuildPhase section */

          /* Begin PBXTargetDependency section */
          		#{id(:dependency)} /* PBXTargetDependency */ = {
          			isa = PBXTargetDependency;
          			target = #{id(:app_target)} /* #{@name} */;
          			targetProxy = #{id(:proxy)} /* PBXContainerItemProxy */;
          		};
          /* End PBXTargetDependency section */

          /* Begin XCBuildConfiguration section */
          #{configuration(:project_debug, "Debug", project_settings + ['DEBUG_INFORMATION_FORMAT = dwarf', 'ENABLE_TESTABILITY = YES', 'GCC_OPTIMIZATION_LEVEL = 0', 'ONLY_ACTIVE_ARCH = YES', 'SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG', 'SWIFT_OPTIMIZATION_LEVEL = "-Onone"'])}
          #{configuration(:project_release, "Release", project_settings + ['DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym"', 'SWIFT_COMPILATION_MODE = wholemodule'])}
          #{configuration(:app_debug, "Debug", app_settings)}
          #{configuration(:app_release, "Release", app_settings)}
          #{configuration(:test_debug, "Debug", test_settings)}
          #{configuration(:test_release, "Release", test_settings)}
          /* End XCBuildConfiguration section */

          /* Begin XCConfigurationList section */
          #{configuration_list(:project_configurations, %(PBXProject "#{@name}"), :project_debug, :project_release)}
          #{configuration_list(:app_configurations, %(PBXNativeTarget "#{@name}"), :app_debug, :app_release)}
          #{configuration_list(:test_configurations, %(PBXNativeTarget "#{@name}UITests"), :test_debug, :test_release)}
          /* End XCConfigurationList section */

          /* Begin XCLocalSwiftPackageReference section */
          #{each_package { |_, path, n| %(\t\t#{id(:package, n)} /* XCLocalSwiftPackageReference "#{path}" */ = {\n\t\t\tisa = XCLocalSwiftPackageReference;\n\t\t\trelativePath = #{path};\n\t\t};) }}
          /* End XCLocalSwiftPackageReference section */

          /* Begin XCSwiftPackageProductDependency section */
          #{each_package { |product, _, n| "\t\t#{id(:package_product, n)} /* #{product} */ = {\n\t\t\tisa = XCSwiftPackageProductDependency;\n\t\t\tproductName = #{product};\n\t\t};" }}
          /* End XCSwiftPackageProductDependency section */
          	};
          	rootObject = #{id(:project)} /* Project object */;
          }
        PBXPROJ
      end

      def scheme
        app = buildable(:app_target, "#{@name}.app", @name)
        <<~SCHEME
          <?xml version="1.0" encoding="UTF-8"?>
          <Scheme LastUpgradeVersion = "2720" version = "1.7">
             <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
                <BuildActionEntries>
                   <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
                      #{app}
                   </BuildActionEntry>
                </BuildActionEntries>
             </BuildAction>
             <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
                <Testables>
                   <TestableReference skipped = "NO">
                      #{buildable(:test_target, "#{@name}UITests.xctest", "#{@name}UITests")}
                   </TestableReference>
                </Testables>
             </TestAction>
             <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
                <BuildableProductRunnable runnableDebuggingMode = "0">
                   #{app}
                </BuildableProductRunnable>
             </LaunchAction>
          </Scheme>
        SCHEME
      end

      private

      KINDS = %i[project root_group app_group test_group products_group app_target test_target app_sources test_sources frameworks
        app_product test_product proxy dependency package package_product package_build
        project_configurations app_configurations test_configurations
        project_debug project_release app_debug app_release test_debug test_release
        file other build test_file test_build].freeze

      # An object's id: 24 hex digits that say what it is and which one.
      def id(kind, index = 0)
        format("1D%02X%020X", KINDS.index(kind), index)
      end

      # A line, or a few, for every package the app links.
      def each_package
        @packages.each_with_index.map { |(product, path), n| yield product, path, n }.join("\n")
      end

      def swift_files(subfolder)
        Dir.children(@folder.join(subfolder)).select { |file| file.end_with?(".swift") }.sort
      rescue Errno::ENOENT
        []
      end

      def file_reference(id, file, type)
        quoted = file.match?(/\A[\w.]+\z/) ? file : %("#{file}")
        "\t\t#{id} /* #{file} */ = {isa = PBXFileReference; lastKnownFileType = #{type}; path = #{quoted}; sourceTree = \"<group>\"; };"
      end

      def project_settings
        ["ALWAYS_SEARCH_USER_PATHS = NO", "CLANG_ENABLE_MODULES = YES", "IPHONEOS_DEPLOYMENT_TARGET = 17.0", "SDKROOT = iphoneos", "SWIFT_VERSION = 5.0"]
      end

      def app_settings
        ["CODE_SIGN_STYLE = Automatic", "CURRENT_PROJECT_VERSION = 1", "GENERATE_INFOPLIST_FILE = YES",
          %(HEADER_SEARCH_PATHS = "$(SRCROOT)/#{@headers}"), "INFOPLIST_FILE = #{@name}/Info.plist",
          "INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES", "INFOPLIST_KEY_UILaunchScreen_Generation = YES",
          "INFOPLIST_KEY_UISupportedInterfaceOrientations = UIInterfaceOrientationPortrait",
          %(LIBRARY_SEARCH_PATHS = "$(SRCROOT)/#{@libraries}/$(PLATFORM_NAME)"), "MARKETING_VERSION = 0.1",
          %(OTHER_LDFLAGS = (\n\t\t\t\t\t"-linstant_record_app",\n\t\t\t\t\t"-lspinel_rt",\n\t\t\t\t)),
          %(PRODUCT_BUNDLE_IDENTIFIER = "#{@bundle_id}"), %(PRODUCT_NAME = "$(TARGET_NAME)"),
          %(SWIFT_OBJC_BRIDGING_HEADER = "#{@name}/#{@name}-Bridging-Header.h"), "TARGETED_DEVICE_FAMILY = 1"]
      end

      def test_settings
        ["CODE_SIGN_STYLE = Automatic", "GENERATE_INFOPLIST_FILE = YES", %(PRODUCT_BUNDLE_IDENTIFIER = "#{@bundle_id}UITests"),
          %(PRODUCT_NAME = "$(TARGET_NAME)"), "TARGETED_DEVICE_FAMILY = 1", "TEST_TARGET_NAME = #{@name}"]
      end

      def configuration(kind, name, settings)
        lines = settings.sort.map { |setting| "\t\t\t\t#{setting};" }.join("\n")
        "\t\t#{id(kind)} /* #{name} */ = {\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {\n#{lines}\n\t\t\t};\n\t\t\tname = #{name};\n\t\t};"
      end

      def configuration_list(kind, owner, debug, release)
        "\t\t#{id(kind)} /* Build configuration list for #{owner} */ = {\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n" \
          "\t\t\t\t#{id(debug)} /* Debug */,\n\t\t\t\t#{id(release)} /* Release */,\n\t\t\t);\n\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Debug;\n\t\t};"
      end

      def buildable(kind, product, target)
        %(<BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "#{id(kind)}" BuildableName = "#{product}" BlueprintName = "#{target}" ReferencedContainer = "container:#{@name}.xcodeproj">\n            </BuildableReference>)
      end
    end
  end
end
