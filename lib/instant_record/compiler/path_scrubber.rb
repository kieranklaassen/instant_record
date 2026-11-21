require_relative "runner"

module InstantRecord
  class Compiler
    # Replaces a build machine's absolute path prefix inside a compiled Wasm
    # binary with a neutral prefix of identical byte length so data-segment
    # offsets stay intact.
    module PathScrubber
      module_function

      def scrub(path, prefix)
        prefix_bytes = prefix.to_s.b
        raise ArgumentError, "prefix must not be empty" if prefix_bytes.empty?

        data = File.binread(path)
        count = data.scan(prefix_bytes).length
        neutral = ("/build" + "/_" * prefix_bytes.bytesize).byteslice(0, prefix_bytes.bytesize).b
        raise BuildError, "neutral prefix length mismatch" unless neutral.bytesize == prefix_bytes.bytesize

        patched = data.gsub(prefix_bytes, neutral)
        raise BuildError, "scrubbed wasm size changed" unless patched.bytesize == data.bytesize

        File.binwrite(path, patched)
        { count: count, remaining: patched.scan(prefix_bytes).length, size: patched.bytesize }
      end
    end
  end
end
