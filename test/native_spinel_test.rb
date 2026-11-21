require "test_helper"
require "instant_record/compiler/toolchain"
require "open3"
require "tmpdir"

# A screen has to compile for the phone, where there is no CRuby. This builds
# a screen that uses every element with the same compiler as the browser app
# and holds its output to CRuby's, byte for byte.
#
#   INSTANT_RECORD_TOOLCHAIN=config/instant_record_toolchain.env bundle exec rake test TEST=test/native_spinel_test.rb
class NativeSpinelTest < ActiveSupport::TestCase
  SAMPLE = File.expand_path("native/sample_screen.rb", __dir__)

  test "a screen compiled with Spinel prints what CRuby prints" do
    spinel = spinel_binary
    skip "Set INSTANT_RECORD_TOOLCHAIN to a toolchain file that names SPINEL_HOME to run this." unless spinel

    expected, status = Open3.capture2(RbConfig.ruby, SAMPLE, binmode: true)
    assert status.success?
    expected.force_encoding(Encoding::UTF_8)
    first, second, box, odd, missing = expected.lines
    assert_equal 3, JSON.parse(first).dig("children", 0, "children", 0, "children", 0, "children").size
    assert_equal %w[b2 c3], JSON.parse(second).dig("children", 0, "children", 0, "children", 0, "children").map { |row| row["id"] }
    assert_equal ["inbox\n", "9\n", "0\n"], [box, odd, missing]

    Dir.mktmpdir do |dir|
      binary = File.join(dir, "sample")
      log, status = Open3.capture2e(spinel, SAMPLE, "-o", binary)
      assert status.success?, log
      compiled, status = Open3.capture2(binary, binmode: true)
      assert status.success?
      assert_equal expected, compiled.force_encoding(Encoding::UTF_8)
    end
  end

  private

  def spinel_binary
    file = ENV["INSTANT_RECORD_TOOLCHAIN"]
    return unless file && File.file?(file)

    toolchain = InstantRecord::Compiler::Toolchain.load(file)
    binary = File.join(toolchain["SPINEL_HOME"].to_s, "bin/spinel")
    binary if File.executable?(binary)
  end
end
