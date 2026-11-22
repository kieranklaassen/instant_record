require "etc"
require "fileutils"
require "pathname"
require_relative "entry_builder"
require_relative "runner"
require_relative "toolchain"
require_relative "wasm_build"

module InstantRecord
  class Compiler
    # Build the compiled app as a native static library (plus screenless host
    # binary for this machine, or cross-compiled libraries for iOS).
    class NativeBuild
      TARGETS = %w[iphonesimulator iphoneos].freeze
      ENTRIES = (WasmBuild::REACTOR_EXPORTS.split(",").map { |name| name.split(".")[1] } + %w[render action open]).freeze
      CFLAGS = %w[-O2 -Wno-all -ffp-contract=off -DSP_INT_OVERFLOW_MODE_RAISE].freeze
      SQLITE_CFLAGS = %w[-O2 -DSQLITE_THREADSAFE=0 -DSQLITE_OMIT_LOAD_EXTENSION].freeze
      RUNTIME_CFLAGS = %w[-O2 -Wno-all -ffunction-sections -fdata-sections -ffp-contract=off].freeze
      PACKAGES = WasmBuild::SPINEL_PACKAGES
      IOS_MINIMUM = "17.0"

      # Fields of a screen's node that Spinel did not type as a hash of strings.
      # One loose hash anywhere in the app loosens the struct field for every screen.
      def self.loose_node_fields(generated)
        struct = generated[/^struct sp_InstantRecord__Native__Node_s \{(.*?)^\}/m, 1]
        return [] unless struct

        struct.scan(/(\w+) \* ?iv_(link_params|args|props);/).filter_map do |kind, name|
          name unless kind == "sp_StrStrHash"
        end
      end

      # Lines of app/screens where Spinel already knows a hash has the wrong type.
      def self.certain_type_errors(generated)
        found = []
        place = ""
        generated.each_line(chomp: true) do |line|
          if line.start_with?("#line ")
            place = line
          elsif line.include?("(expected Hash)") && line.include?('sp_raise_cls("TypeError"')
            match = place.match(/\A#line (\d+) "(?:app-src\/)?(app\/screens\/[^"]+)"/)
            next unless match

            location = "#{match[2]}:#{match[1]}"
            found << location unless found.include?(location)
          end
        end
        found
      end

      def self.makefile_list(spinel_home, name)
        makefile = File.read(File.join(spinel_home, "Makefile"))
        match = makefile.match(/^#{Regexp.escape(name)} = (.+)$/)
        raise BuildError, "Spinel's Makefile has no #{name}" unless match

        match[1].split
      end

      def initialize(
        workspace:,
        gem_root:,
        toolchain:,
        app_source: nil,
        models: [],
        endpoint: nil,
        target: nil,
        baseline: nil,
        migration_paths: nil,
        out: $stdout
      )
        @workspace = File.expand_path(workspace.to_s)
        @gem_root = File.expand_path(gem_root.to_s)
        @pipeline_dir = File.join(@gem_root, "compiled/pipeline")
        @toolchain = Toolchain.load(toolchain)
        @app_source = app_source ? File.expand_path(app_source.to_s) : nil
        @demo = @app_source.nil?
        @models = models
        @endpoint = endpoint
        @target = target.nil? || target.to_s.empty? ? nil : target.to_s
        if @target && !TARGETS.include?(@target)
          raise ArgumentError, "Unknown target #{@target}. Leave it out for this machine, or use #{TARGETS.join(' or ')}."
        end
        @build_dir = File.join(@workspace, *[".build-native", @target].compact)
        @baseline = baseline
        @migration_paths = migration_paths
        @runner = Runner.new(build_dir: @build_dir)
        @out = out
      end

      def run
        FileUtils.mkdir_p(@build_dir)
        FileUtils.mkdir_p(@toolchain.fetch("CACHE"))

        spinel_home = @toolchain.fetch("SPINEL_HOME")
        path_env = { "PATH" => [File.join(spinel_home, "bin"), ENV.fetch("PATH", "")].join(File::PATH_SEPARATOR) }
        cc = @target ? ios_cc(@target) : [ENV.fetch("CC", "cc")]

        wasm_build = WasmBuild.new(
          workspace: @workspace,
          gem_root: @gem_root,
          toolchain: @toolchain,
          app_source: @app_source,
          models: @models,
          endpoint: @endpoint,
          baseline: @baseline,
          migration_paths: @migration_paths,
          build_dir: @build_dir,
          out: @out
        )
        emitted = wasm_build.emit_tree(native: true)
        app = emitted[:app]
        tree = emitted[:tree]
        plan = emitted[:plan]

        screens = EntryBuilder.write_native_entry(
          tree_dir: tree,
          app_dir: app,
          demo: @demo,
          models: @models,
          migration_plan: plan
        )
        @out.puts "wrote main_native.rb with screens: #{screens.empty? ? 'none' : screens.join(', ')}"

        out_dir = File.join(tree, "build")
        FileUtils.mkdir_p(out_dir)
        app_c = File.join(out_dir, "app.c")
        sqlite_src = @toolchain.fetch("SQLITE_SRC")

        flags = @runner.run(["spin", "flags"], cwd: tree, env: path_env).split
        @runner.run(
          [
            "spinel", "-c", "--force",
            "--ext-init", "app_boot",
            "--ext-entry", ENTRIES.map { |entry| "NativeBridge.#{entry}" }.join(","),
            *flags, "main_native.rb", "-o", app_c
          ],
          cwd: tree,
          env: path_env.merge("CPATH" => sqlite_src),
          log: "spinel.log"
        )

        check_generated_c!(app_c)

        includes = [
          "-I#{File.join(spinel_home, 'lib')}",
          "-I#{File.join(spinel_home, 'lib/regexp')}",
          "-I#{sqlite_src}",
          "-I#{out_dir}",
          "-I#{File.join(@pipeline_dir, 'native')}"
        ]

        objects = [
          [app_c, CFLAGS],
          [File.join(@pipeline_dir, "native_shim.c"), CFLAGS],
          [File.join(@pipeline_dir, "sqlite/rh_shim.c"), CFLAGS],
          [File.join(sqlite_src, "sqlite3.c"), SQLITE_CFLAGS]
        ].map do |source, cflags|
          made = File.join(out_dir, "#{File.basename(source, '.c')}.o")
          @runner.run([*cc, *cflags, *includes, "-c", source, "-o", made], log: "cc.log")
          made
        end

        if @target
          runtime = File.join(@build_dir, "libspinel_rt.a")
          objects.concat(cross_runtime(cc, spinel_home, out_dir, runtime))
        else
          objects.concat(PACKAGES.map { |name| File.join(spinel_home, "packages", name, "sp_#{name}.o") })
        end

        library = File.join(@build_dir, "libinstant_record_app.a")
        File.delete(library) if File.exist?(library)
        @runner.run(["ar", "rcs", library, *objects])

        if @target
          @out.puts "built #{library} and #{runtime} for #{@target}"
          return Pathname(@build_dir)
        end

        host = File.join(@build_dir, "host")
        @runner.run(
          [
            *cc, "-O2", *includes,
            File.join(@pipeline_dir, "native/host.c"),
            library,
            File.join(spinel_home, "lib/libspinel_rt.a"),
            "-lm", "-o", host
          ],
          log: "link.log"
        )
        @out.puts "built #{library} and #{host} (#{File.size(host)} bytes)"
        Pathname(@build_dir)
      end

      private

      def check_generated_c!(app_c)
        generated = File.binread(app_c).force_encoding(Encoding::UTF_8).scrub
        loose = self.class.loose_node_fields(generated)
        unless loose.empty?
          raise BuildError,
            "Some screen gives params: or args: a hash that does not hold only strings (the compiler typed a node's " \
            "#{loose.join(', ')} loosely). Call to_s on a value that comes from a record, and write Node.strings for an empty hash."
        end

        wrong = self.class.certain_type_errors(generated)
        unless wrong.empty?
          raise BuildError,
            "A hash given to params: or args: must hold strings. Call to_s on a value that comes from a record:\n  " \
            "#{wrong.join("\n  ")}"
        end
      end

      def ios_cc(target)
        sdk = @runner.run(["xcrun", "--sdk", target, "--show-sdk-path"]).strip
        arch = Etc.uname[:machine]
        triple = target == "iphoneos" ? "arm64-apple-ios#{IOS_MINIMUM}" : "#{arch}-apple-ios#{IOS_MINIMUM}-simulator"
        ["xcrun", "--sdk", target, "clang", "-target", triple, "-isysroot", sdk]
      end

      def cross_runtime(cc, spinel_home, out_dir, runtime)
        lib = File.join(spinel_home, "lib")
        regexp = ["-I#{File.join(lib, 'regexp')}", "-I#{File.join(lib, 'regexp/shim')}"]
        sources = self.class.makefile_list(spinel_home, "RE_SRC").map { |path| [File.join(spinel_home, path), regexp] }
        sources.concat(
          self.class.makefile_list(spinel_home, "RT_MEMBERS").map { |member| [File.join(lib, "#{member}.c"), ["-I#{lib}", *regexp]] }
        )

        objects = sources.map do |source, includes|
          target_obj = File.join(out_dir, "rt_#{File.basename(source, '.c')}.o")
          @runner.run([*cc, *RUNTIME_CFLAGS, *includes, "-c", source, "-o", target_obj], log: "cc.log")
          target_obj
        end

        File.delete(runtime) if File.exist?(runtime)
        @runner.run(["ar", "rcs", runtime, *objects])

        PACKAGES.map do |name|
          folder = File.join(spinel_home, "packages", name)
          target_obj = File.join(out_dir, "sp_#{name}.o")
          @runner.run([*cc, *RUNTIME_CFLAGS, "-I#{lib}", "-I#{folder}", "-c", File.join(folder, "sp_#{name}.c"), "-o", target_obj], log: "cc.log")
          target_obj
        end
      end
    end
  end
end
