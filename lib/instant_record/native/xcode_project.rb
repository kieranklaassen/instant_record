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
        app = sources
        tests = ui_tests
        others = ["#{@name}-Bridging-Header.h", "Info.plist"]

        sections = [
          build_files_section(app, tests),
          container_item_proxy_section,
          file_references_section(app, others, tests),
          frameworks_build_phase_section,
          groups_section(app, others, tests),
          native_targets_section,
          project_section,
          sources_build_phases_section(app, tests),
          target_dependency_section,
          build_configurations_section,
          configuration_lists_section,
          local_swift_package_reference_section,
          swift_package_product_dependency_section
        ].join("\n\n")

        <<~PBXPROJ
          // !$*UTF8*$!
          {
          	archiveVersion = 1;
          	classes = {
          	};
          	objectVersion = 60;
          	objects = {

          #{sections}
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
      KIND_INDEX = KINDS.each_with_index.to_h.freeze

      PROJECT_DEBUG_SETTINGS = [
        "DEBUG_INFORMATION_FORMAT = dwarf",
        "ENABLE_TESTABILITY = YES",
        "GCC_OPTIMIZATION_LEVEL = 0",
        "ONLY_ACTIVE_ARCH = YES",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG",
        'SWIFT_OPTIMIZATION_LEVEL = "-Onone"'
      ].freeze

      PROJECT_RELEASE_SETTINGS = [
        'DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym"',
        "SWIFT_COMPILATION_MODE = wholemodule"
      ].freeze

      # An object's id: 24 hex digits that say what it is and which one.
      def id(kind, index = 0)
        kind_index = KIND_INDEX.fetch(kind) { raise KeyError, "unknown XcodeProject object kind: #{kind.inspect}" }
        format("1D%02X%020X", kind_index, index)
      end

      # A line, or a few, for every package the app links.
      def each_package
        @packages.each_with_index.map { |(product, path), n| yield product, path, n }.join("\n")
      end

      def swift_files(subfolder)
        dir = @folder.join(subfolder)
        Dir.children(dir).select { |file| file.end_with?(".swift") && dir.join(file).file? }.sort
      rescue Errno::ENOENT, Errno::ENOTDIR
        []
      end

      def pbxproj_section(name, body)
        "/* Begin #{name} section */\n#{body}\n/* End #{name} section */"
      end

      def pbx_object(body)
        body.chomp.gsub(/^(?=.)/, "\t\t")
      end

      def build_files_section(app, tests)
        pbxproj_section("PBXBuildFile", [
          build_file_entries(app, :build, :file),
          build_file_entries(tests, :test_build, :test_file),
          each_package { |product, _, n| package_build_file_entry(product, n) }
        ].join("\n"))
      end

      def build_file_entries(files, build_kind, file_kind)
        files.each_with_index.map do |file, n|
          "\t\t#{id(build_kind, n)} /* #{file} in Sources */ = {isa = PBXBuildFile; fileRef = #{id(file_kind, n)} /* #{file} */; };"
        end.join("\n")
      end

      def package_build_file_entry(product, index)
        "\t\t#{id(:package_build, index)} /* #{product} in Frameworks */ = {isa = PBXBuildFile; productRef = #{id(:package_product, index)} /* #{product} */; };"
      end

      def container_item_proxy_section
        pbxproj_section("PBXContainerItemProxy", pbx_object(<<~PBX))
          #{id(:proxy)} /* PBXContainerItemProxy */ = {
          	isa = PBXContainerItemProxy;
          	containerPortal = #{id(:project)} /* Project object */;
          	proxyType = 1;
          	remoteGlobalIDString = #{id(:app_target)};
          	remoteInfo = #{@name};
          };
        PBX
      end

      def file_references_section(app, others, tests)
        pbxproj_section("PBXFileReference", [
          file_reference_entries(app, :file) { "sourcecode.swift" },
          file_reference_entries(others, :other) { |file| file.end_with?(".h") ? "sourcecode.c.h" : "text.plist.xml" },
          file_reference_entries(tests, :test_file) { "sourcecode.swift" },
          product_reference(:app_product, "#{@name}.app", "wrapper.application"),
          product_reference(:test_product, "#{@name}UITests.xctest", "wrapper.cfbundle")
        ].join("\n"))
      end

      def file_reference_entries(files, kind)
        files.each_with_index.map { |file, n| file_reference(id(kind, n), file, yield(file)) }.join("\n")
      end

      def file_reference(object_id, file, type)
        quoted = file.match?(/\A[\w.]+\z/) ? file : %("#{file}")
        "\t\t#{object_id} /* #{file} */ = {isa = PBXFileReference; lastKnownFileType = #{type}; path = #{quoted}; sourceTree = \"<group>\"; };"
      end

      def product_reference(kind, product, file_type)
        "\t\t#{id(kind)} /* #{product} */ = {isa = PBXFileReference; explicitFileType = #{file_type}; includeInIndex = 0; path = #{product}; sourceTree = BUILT_PRODUCTS_DIR; };"
      end

      def frameworks_build_phase_section
        files = each_package { |product, _, n| "\t\t#{id(:package_build, n)} /* #{product} in Frameworks */," }
        pbxproj_section("PBXFrameworksBuildPhase", pbx_object(<<~PBX))
          #{id(:frameworks)} /* Frameworks */ = {
          	isa = PBXFrameworksBuildPhase;
          	buildActionMask = 2147483647;
          	files = (
          #{files}
          	);
          	runOnlyForDeploymentPostprocessing = 0;
          };
        PBX
      end

      def groups_section(app, others, tests)
        pbxproj_section("PBXGroup", [
          group(:root_group, children: [
            group_child(id(:app_group), @name),
            group_child(id(:test_group), "#{@name}UITests"),
            group_child(id(:products_group), "Products")
          ]),
          group(:app_group, comment: @name, path: @name, children: group_children(app, :file) + group_children(others, :other)),
          group(:test_group, comment: "#{@name}UITests", path: "#{@name}UITests", children: group_children(tests, :test_file)),
          group(:products_group, comment: "Products", name: "Products", children: [
            group_child(id(:app_product), "#{@name}.app"),
            group_child(id(:test_product), "#{@name}UITests.xctest")
          ])
        ].join("\n"))
      end

      def group(kind, children:, comment: nil, path: nil, name: nil)
        header = comment ? "#{id(kind)} /* #{comment} */" : id(kind)
        attrs = []
        attrs << "\tpath = #{path};" if path
        attrs << "\tname = #{name};" if name
        attrs << %(\tsourceTree = "<group>";)

        pbx_object(<<~PBX)
          #{header} = {
          	isa = PBXGroup;
          	children = (
          #{children.join("\n")}
          	);
          #{attrs.join("\n")}
          };
        PBX
      end

      def group_children(files, kind)
        files.each_with_index.map { |file, n| group_child(id(kind, n), file) }
      end

      def group_child(object_id, label)
        "\t\t#{object_id} /* #{label} */,"
      end

      def native_targets_section
        pbxproj_section("PBXNativeTarget", [
          app_native_target,
          test_native_target
        ].join("\n"))
      end

      def app_native_target
        package_deps = each_package { |product, _, n| "\t\t#{id(:package_product, n)} /* #{product} */," }
        pbx_object(<<~PBX)
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
          #{package_deps}
          	);
          	productName = #{@name};
          	productReference = #{id(:app_product)} /* #{@name}.app */;
          	productType = "com.apple.product-type.application";
          };
        PBX
      end

      def test_native_target
        pbx_object(<<~PBX)
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
        PBX
      end

      def project_section
        package_refs = each_package { |_, path, n| %(\t\t#{id(:package, n)} /* XCLocalSwiftPackageReference "#{path}" */,) }
        pbxproj_section("PBXProject", pbx_object(<<~PBX))
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
          #{package_refs}
          	);
          	productRefGroup = #{id(:products_group)} /* Products */;
          	projectDirPath = "";
          	projectRoot = "";
          	targets = (
          		#{id(:app_target)} /* #{@name} */,
          		#{id(:test_target)} /* #{@name}UITests */,
          	);
          };
        PBX
      end

      def sources_build_phases_section(app, tests)
        pbxproj_section("PBXSourcesBuildPhase", [
          sources_phase(:app_sources, :build, app),
          sources_phase(:test_sources, :test_build, tests)
        ].join("\n"))
      end

      def sources_phase(phase_kind, build_kind, files)
        entries = files.each_with_index.map { |file, n| "\t\t#{id(build_kind, n)} /* #{file} in Sources */," }.join("\n")
        pbx_object(<<~PBX)
          #{id(phase_kind)} /* Sources */ = {
          	isa = PBXSourcesBuildPhase;
          	buildActionMask = 2147483647;
          	files = (
          #{entries}
          	);
          	runOnlyForDeploymentPostprocessing = 0;
          };
        PBX
      end

      def target_dependency_section
        pbxproj_section("PBXTargetDependency", pbx_object(<<~PBX))
          #{id(:dependency)} /* PBXTargetDependency */ = {
          	isa = PBXTargetDependency;
          	target = #{id(:app_target)} /* #{@name} */;
          	targetProxy = #{id(:proxy)} /* PBXContainerItemProxy */;
          };
        PBX
      end

      def build_configurations_section
        pbxproj_section("XCBuildConfiguration", [
          configuration(:project_debug, "Debug", project_settings + PROJECT_DEBUG_SETTINGS),
          configuration(:project_release, "Release", project_settings + PROJECT_RELEASE_SETTINGS),
          configuration(:app_debug, "Debug", app_settings),
          configuration(:app_release, "Release", app_settings),
          configuration(:test_debug, "Debug", test_settings),
          configuration(:test_release, "Release", test_settings)
        ].join("\n"))
      end

      def configuration_lists_section
        pbxproj_section("XCConfigurationList", [
          configuration_list(:project_configurations, %(PBXProject "#{@name}"), :project_debug, :project_release),
          configuration_list(:app_configurations, %(PBXNativeTarget "#{@name}"), :app_debug, :app_release),
          configuration_list(:test_configurations, %(PBXNativeTarget "#{@name}UITests"), :test_debug, :test_release)
        ].join("\n"))
      end

      def local_swift_package_reference_section
        pbxproj_section("XCLocalSwiftPackageReference", each_package do |_, path, n|
          pbx_object(<<~PBX)
            #{id(:package, n)} /* XCLocalSwiftPackageReference "#{path}" */ = {
            	isa = XCLocalSwiftPackageReference;
            	relativePath = #{path};
            };
          PBX
        end)
      end

      def swift_package_product_dependency_section
        pbxproj_section("XCSwiftPackageProductDependency", each_package do |product, _, n|
          pbx_object(<<~PBX)
            #{id(:package_product, n)} /* #{product} */ = {
            	isa = XCSwiftPackageProductDependency;
            	productName = #{product};
            };
          PBX
        end)
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
          %(OTHER_LDFLAGS = (\n\t"-linstant_record_app",\n\t"-lspinel_rt",\n)),
          %(PRODUCT_BUNDLE_IDENTIFIER = "#{@bundle_id}"), %(PRODUCT_NAME = "$(TARGET_NAME)"),
          %(SWIFT_OBJC_BRIDGING_HEADER = "#{@name}/#{@name}-Bridging-Header.h"), "TARGETED_DEVICE_FAMILY = 1"]
      end

      def test_settings
        ["CODE_SIGN_STYLE = Automatic", "GENERATE_INFOPLIST_FILE = YES", %(PRODUCT_BUNDLE_IDENTIFIER = "#{@bundle_id}UITests"),
          %(PRODUCT_NAME = "$(TARGET_NAME)"), "TARGETED_DEVICE_FAMILY = 1", "TEST_TARGET_NAME = #{@name}"]
      end

      def configuration(kind, name, settings)
        lines = settings.sort.map { |setting| "#{setting};".gsub(/^/, "\t\t") }.join("\n")
        pbx_object(<<~PBX)
          #{id(kind)} /* #{name} */ = {
          	isa = XCBuildConfiguration;
          	buildSettings = {
          #{lines}
          	};
          	name = #{name};
          };
        PBX
      end

      def configuration_list(kind, owner, debug, release)
        pbx_object(<<~PBX)
          #{id(kind)} /* Build configuration list for #{owner} */ = {
          	isa = XCConfigurationList;
          	buildConfigurations = (
          		#{id(debug)} /* Debug */,
          		#{id(release)} /* Release */,
          	);
          	defaultConfigurationIsVisible = 0;
          	defaultConfigurationName = Debug;
          };
        PBX
      end

      def buildable(kind, product, target)
        %(<BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "#{id(kind)}" BuildableName = "#{product}" BlueprintName = "#{target}" ReferencedContainer = "container:#{@name}.xcodeproj">\n            </BuildableReference>)
      end
    end
  end
end
