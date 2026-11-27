require "digest"
require "etc"
require "fileutils"
require "json"
require "open3"
require "pathname"
require "rbconfig"
require "securerandom"
require_relative "entry_builder"
require_relative "kotlin_codegen"
require_relative "native_contracts"
require_relative "runner"
require_relative "swift_codegen"
require_relative "toolchain"
require_relative "wasm_build"

module InstantRecord
  class Compiler
    # Build the compiled app as a native static library (plus screenless host
    # binary and Fiddle-loadable shared library for this machine, or
    # cross-compiled libraries for iOS).
    class NativeBuild
      CACHE_SCHEMA_VERSION = 1
      TARGETS = %w[iphonesimulator iphoneos].freeze
      ENTRIES = (WasmBuild::REACTOR_EXPORTS.split(",").map { |name| name.split(".")[1] } + %w[render action open]).freeze
      CFLAGS = %w[-O2 -Wno-all -ffp-contract=off -DSP_INT_OVERFLOW_MODE_RAISE].freeze
      SQLITE_CFLAGS = %w[-O2 -DSQLITE_THREADSAFE=0 -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_ENABLE_FTS5].freeze
      RUNTIME_CFLAGS = %w[-O2 -Wno-all -ffunction-sections -fdata-sections -ffp-contract=off].freeze
      PACKAGES = WasmBuild::SPINEL_PACKAGES
      IOS_MINIMUM = "17.0"

      def self.shared_library_name
        darwin? ? "libinstant_record_app.dylib" : "libinstant_record_app.so"
      end

      def self.darwin?
        RbConfig::CONFIG["host_os"].to_s.match?(/darwin/i)
      end

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
        sync_windows: nil,
        endpoint: nil,
        mount_path: nil,
        target: nil,
        baseline: nil,
        migration_paths: nil,
        island: nil,
        overrides: nil,
        swift_out: nil,
        kotlin: false,
        kotlin_out: nil,
        kotlin_package: "dev.instantrecord.contracts",
        out: $stdout
      )
        @workspace = File.expand_path(workspace.to_s)
        @gem_root = File.expand_path(gem_root.to_s)
        @pipeline_dir = File.join(@gem_root, "compiled/pipeline")
        @toolchain = Toolchain.load(toolchain)
        @app_source = app_source ? File.expand_path(app_source.to_s) : nil
        @demo = @app_source.nil?
        @source_root = @app_source || File.join(@gem_root, "demo")
        @models = models
        @sync_windows = sync_windows
        @endpoint = (endpoint && !endpoint.to_s.empty?) ? endpoint.to_s.sub(%r{/+\z}, "") : nil
        @mount_path = (mount_path && !mount_path.to_s.empty?) ? mount_path.to_s.sub(%r{/+\z}, "") : nil
        @target = target.nil? || target.to_s.empty? ? nil : target.to_s
        if @target && !TARGETS.include?(@target)
          raise ArgumentError, "Unknown target #{@target}. Leave it out for this machine, or use #{TARGETS.join(' or ')}."
        end
        @build_dir = File.join(@workspace, *[".build-native", @target].compact)
        @baseline = baseline
        @migration_paths = migration_paths
        @island = island
        @overrides = overrides
        @swift_out = swift_out ? File.expand_path(swift_out.to_s) : nil
        @kotlin = !!kotlin || !kotlin_out.nil?
        @kotlin_out = kotlin_out ? File.expand_path(kotlin_out.to_s) : nil
        @kotlin_package = kotlin_package.to_s
        @runner = Runner.new(build_dir: @build_dir)
        @out = out
      end

      def run
        @file_digests = {}
        @dir_header_digests = {}
        FileUtils.mkdir_p(@build_dir)
        FileUtils.mkdir_p(object_cache_dir)

        generate_contracts

        spinel_home = @toolchain.fetch("SPINEL_HOME")
        path_env = { "PATH" => [File.join(spinel_home, "bin"), ENV.fetch("PATH", "")].join(File::PATH_SEPARATOR) }
        cc, toolchain_identity = resolve_compiler

        wasm_build = WasmBuild.new(
          workspace: @workspace,
          gem_root: @gem_root,
          toolchain: @toolchain,
          app_source: @app_source,
          models: @models,
          sync_windows: @sync_windows,
          endpoint: @endpoint,
          mount_path: @mount_path,
          baseline: @baseline,
          migration_paths: @migration_paths,
          island: @island,
          overrides: @overrides,
          build_dir: @build_dir,
          out: @out
        )
        emitted = wasm_build.emit_tree(native: true)
        app = emitted[:app]
        tree = emitted[:tree]
        plan = emitted[:plan]
        manifest = emitted[:manifest]

        screens = EntryBuilder.write_native_entry(
          tree_dir: tree,
          app_dir: app,
          demo: @demo,
          manifest: manifest,
          models: @models,
          sync_windows: @sync_windows,
          endpoint: @endpoint,
          mount_path: @mount_path,
          migration_plan: plan,
          shell_fingerprint: emitted[:shell_fingerprint]
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

        pic = @target ? [] : ["-fPIC"]
        app_obj = File.join(out_dir, "app.o")
        @runner.run([*cc, *self.class::CFLAGS, *pic, *includes, "-c", app_c, "-o", app_obj], log: "cc.log")

        sqlite_headers = header_entries([File.join(sqlite_src, "sqlite3.h")])
        native_shim_headers = header_entries([
          File.join(@pipeline_dir, "native/instant_record_native.h"),
          File.join(out_dir, "app.h")
        ]) + [["spinel_lib_headers", directory_headers_digest(File.join(spinel_home, "lib"))]]

        objects = [
          app_obj,
          cached_object(
            name: "native_shim",
            source: File.join(@pipeline_dir, "native_shim.c"),
            cflags: self.class::CFLAGS + pic,
            includes: includes,
            cc: cc,
            toolchain_identity: toolchain_identity,
            extra_inputs: native_shim_headers
          ),
          cached_object(
            name: "rh_shim",
            source: File.join(@pipeline_dir, "sqlite/rh_shim.c"),
            cflags: self.class::CFLAGS + pic,
            includes: ["-I#{sqlite_src}"],
            cc: cc,
            toolchain_identity: toolchain_identity,
            extra_inputs: sqlite_headers
          ),
          cached_object(
            name: "sqlite3",
            source: File.join(sqlite_src, "sqlite3.c"),
            cflags: self.class::SQLITE_CFLAGS + pic,
            includes: ["-I#{sqlite_src}"],
            cc: cc,
            toolchain_identity: toolchain_identity,
            extra_inputs: sqlite_headers
          )
        ]

        if @target
          runtime = File.join(@build_dir, "libspinel_rt.a")
          objects.concat(cross_runtime(cc, spinel_home, runtime, toolchain_identity))
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

        shared = File.join(@build_dir, self.class.shared_library_name)
        shared_args =
          if self.class.darwin?
            ["-dynamiclib", "-O2", "-Wl,-force_load,#{library}", File.join(spinel_home, "lib/libspinel_rt.a")]
          else
            ["-shared", "-O2", "-Wl,--whole-archive", library, "-Wl,--no-whole-archive", File.join(spinel_home, "lib/libspinel_rt.a")]
          end
        @runner.run([*cc, *shared_args, "-lm", "-o", shared], log: "link-shared.log")

        @out.puts "built #{library}, #{shared} and #{host} (#{File.size(host)} bytes)"
        Pathname(@build_dir)
      end

      def generate_contracts
        screens_dir = File.join(@source_root, "app/screens")
        contracts = NativeContracts.extract_dir(screens_dir)
        return [] if contracts.empty?

        generated_dir = File.join(@build_dir, "generated")
        FileUtils.mkdir_p(generated_dir)

        swift_source = SwiftCodegen.generate(contracts)
        swift_path = File.join(generated_dir, "InstantRecordContracts.swift")
        File.write(swift_path, swift_source)
        if @swift_out && @swift_out != swift_path
          FileUtils.mkdir_p(File.dirname(@swift_out))
          File.write(@swift_out, swift_source)
        end
        @out.puts "wrote #{swift_path} (#{contracts.size} contracts)"

        if @kotlin
          kotlin_source = KotlinCodegen.generate(contracts, package: @kotlin_package)
          kotlin_path = File.join(generated_dir, "InstantRecordContracts.kt")
          File.write(kotlin_path, kotlin_source)
          if @kotlin_out && @kotlin_out != kotlin_path
            FileUtils.mkdir_p(File.dirname(@kotlin_out))
            File.write(@kotlin_out, kotlin_source)
          end
          @out.puts "wrote #{kotlin_path} (#{contracts.size} contracts)"
        end

        contracts
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

      def resolve_compiler
        if @target
          sdk = @runner.run(["xcrun", "--sdk", @target, "--show-sdk-path"]).strip
          arch = Etc.uname[:machine]
          triple = @target == "iphoneos" ? "arm64-apple-ios#{IOS_MINIMUM}" : "#{arch}-apple-ios#{IOS_MINIMUM}-simulator"
          cc = ["xcrun", "--sdk", @target, "clang", "-target", triple, "-isysroot", sdk]
          identity = {
            "target" => @target,
            "triple" => triple,
            "sdk_path" => sdk,
            "sdk_version" => probe_output(["xcrun", "--sdk", @target, "--show-sdk-version"], required: true),
            "sdk_build_version" => probe_output(["xcrun", "--sdk", @target, "--show-sdk-build-version"], required: true),
            "compiler_version" => probe_output(["xcrun", "--sdk", @target, "clang", "--version"], required: true)
          }
          [cc, identity]
        else
          cc_bin = ENV.fetch("CC", "cc")
          identity = {
            "target" => "host",
            "platform" => "#{Etc.uname[:sysname]}-#{Etc.uname[:machine]}",
            "cc" => Toolchain.which(cc_bin) || cc_bin,
            "sdkroot" => ENV["SDKROOT"].to_s,
            "deployment_target" => ENV["MACOSX_DEPLOYMENT_TARGET"].to_s,
            "compiler_version" => probe_output([cc_bin, "--version"])
          }
          [[cc_bin], identity]
        end
      end

      def probe_output(cmd, required: false)
        argv = cmd.map(&:to_s)
        stdout, stderr, status = Open3.capture3([argv.first, argv.first], *argv[1..])
        unless status.success?
          raise BuildError, "build step failed: #{argv.join(' ')}\n#{stderr.strip}" if required

          return ""
        end

        out = stdout.strip
        out.empty? ? stderr.strip : out
      rescue Errno::ENOENT => e
        raise BuildError, "build step failed: executable #{argv.first.inspect} not found (#{e.message})" if required

        ""
      end

      def object_cache_dir
        File.join(@toolchain.fetch("CACHE"), "native-objects")
      end

      def file_digest(path)
        @file_digests ||= {}
        @file_digests[path] ||= Digest::SHA256.file(path).hexdigest
      end

      def header_entries(paths)
        paths.filter_map do |path|
          next unless File.file?(path)

          [File.basename(path), file_digest(path)]
        end
      end

      def directory_headers_digest(dir, pattern: "**/*.{h,hh,hpp,inc,def}", exclude: [])
        @dir_header_digests ||= {}
        excluded = exclude.map { |path| File.expand_path(path) }.sort
        @dir_header_digests[[dir, pattern, excluded]] ||= begin
          digest = Digest::SHA256.new
          if File.directory?(dir)
            Dir.glob(pattern, base: dir).sort.each do |rel|
              full = File.expand_path(rel, dir)
              next if excluded.include?(full) || !File.file?(full)

              digest.update(JSON.generate([rel, file_digest(full)]))
            end
          end
          digest.hexdigest
        end
      end

      def object_cache_key(name:, source:, cflags:, toolchain_identity:, extra_inputs:)
        payload = {
          "schema" => CACHE_SCHEMA_VERSION,
          "kind" => "object",
          "name" => name.to_s,
          "toolchain" => toolchain_identity,
          "cflags" => cflags.map(&:to_s),
          "source" => file_digest(source),
          "extra_inputs" => extra_inputs
        }
        Digest::SHA256.hexdigest(JSON.generate(payload))
      end

      def archive_cache_key(name:, cflags:, toolchain_identity:, member_keys:)
        payload = {
          "schema" => CACHE_SCHEMA_VERSION,
          "kind" => "archive",
          "name" => name.to_s,
          "toolchain" => toolchain_identity,
          "cflags" => cflags.map(&:to_s),
          "members" => member_keys
        }
        Digest::SHA256.hexdigest(JSON.generate(payload))
      end

      def cached_object(cc:, **inputs)
        compile_keyed_object(cc: cc, **keyed_object(**inputs))
      end

      def keyed_object(name:, source:, cflags:, includes:, toolchain_identity:, extra_inputs:)
        key = object_cache_key(
          name: name,
          source: source,
          cflags: cflags,
          toolchain_identity: toolchain_identity,
          extra_inputs: extra_inputs
        )
        { name: name, source: source, cflags: cflags, includes: includes, key: key }
      end

      def compile_keyed_object(name:, source:, cflags:, includes:, key:, cc:)
        cached_path = File.join(object_cache_dir, "#{name}-#{key}.o")
        fetch_cached_file(cached_path) do |tmp_path|
          @runner.run([*cc, *cflags, *includes, "-c", source, "-o", tmp_path], log: "cc.log")
        end
      end

      def fetch_cached_file(cached_path, &block)
        return cached_path if File.file?(cached_path) && !File.zero?(cached_path)

        with_atomic_write(cached_path, &block)
      end

      def copy_atomically(src, dst)
        with_atomic_write(dst) { |tmp_path| FileUtils.cp(src, tmp_path) }
      end

      def with_atomic_write(dest_path)
        dir = File.dirname(dest_path)
        FileUtils.mkdir_p(dir)
        base = File.basename(dest_path)
        ext = File.extname(base)
        stem = File.basename(base, ext)
        tmp_path = File.join(dir, ".#{stem}.#{Process.pid}.#{Thread.current.object_id}.#{SecureRandom.hex(6)}.tmp#{ext}")

        begin
          yield tmp_path
          unless File.file?(tmp_path) && !File.zero?(tmp_path)
            raise BuildError, "Expected build step to produce non-empty #{tmp_path}"
          end
          File.rename(tmp_path, dest_path)
        ensure
          FileUtils.rm_f(tmp_path) if File.exist?(tmp_path)
        end

        dest_path
      end

      def sanitize_cache_name(value)
        value.to_s.gsub(/[^A-Za-z0-9_.-]+/, "_")
      end

      def cross_runtime(cc, spinel_home, runtime, toolchain_identity)
        lib = File.join(spinel_home, "lib")
        regexp_dir = File.join(lib, "regexp")
        regexp = ["-I#{regexp_dir}", "-I#{File.join(regexp_dir, 'shim')}"]
        runtime_cflags = self.class::RUNTIME_CFLAGS
        re_src_paths = self.class.makefile_list(spinel_home, "RE_SRC")
        re_src_full = re_src_paths.map { |path| File.join(spinel_home, path) }

        regexp_headers = [[
          "spinel_regexp_headers",
          directory_headers_digest(regexp_dir, pattern: "**/*.{c,h,hh,hpp,inc,def}", exclude: re_src_full)
        ]]
        lib_headers = [["spinel_lib_headers", directory_headers_digest(lib)]]

        members = re_src_paths.map do |path|
          keyed_object(
            name: "re_#{sanitize_cache_name(path.delete_suffix('.c'))}",
            source: File.join(spinel_home, path),
            cflags: runtime_cflags,
            includes: regexp,
            extra_inputs: regexp_headers,
            toolchain_identity: toolchain_identity
          )
        end

        members.concat(
          self.class.makefile_list(spinel_home, "RT_MEMBERS").map do |member|
            keyed_object(
              name: "rt_#{sanitize_cache_name(member)}",
              source: File.join(lib, "#{member}.c"),
              cflags: runtime_cflags,
              includes: ["-I#{lib}", *regexp],
              extra_inputs: lib_headers,
              toolchain_identity: toolchain_identity
            )
          end
        )

        archive_key = archive_cache_key(
          name: "libspinel_rt",
          cflags: runtime_cflags,
          toolchain_identity: toolchain_identity,
          member_keys: members.map { |member| [member[:name], member[:key]] }
        )
        cached_archive = File.join(object_cache_dir, "libspinel_rt-#{archive_key}.a")

        fetch_cached_file(cached_archive) do |tmp_archive|
          objects = members.map { |member| compile_keyed_object(cc: cc, **member) }
          @runner.run(["ar", "rcs", tmp_archive, *objects])
        end

        copy_atomically(cached_archive, runtime)

        PACKAGES.map do |name|
          folder = File.join(spinel_home, "packages", name)
          source = File.join(folder, "sp_#{name}.c")
          pkg_headers = lib_headers + [[
            "package_#{name}_headers",
            directory_headers_digest(folder, pattern: "**/*.{c,h,hh,hpp,inc,def}", exclude: [source])
          ]]
          cached_object(
            name: "sp_#{sanitize_cache_name(name)}",
            source: source,
            cflags: runtime_cflags,
            includes: ["-I#{lib}", "-I#{folder}"],
            cc: cc,
            toolchain_identity: toolchain_identity,
            extra_inputs: pkg_headers
          )
        end
      end
    end
  end
end
