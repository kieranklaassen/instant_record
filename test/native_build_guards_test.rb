require "test_helper"
require "json"
require "open3"
require "tempfile"

# The two checks build_native.py makes of the C the compiler wrote, with canned C: they need
# no toolchain, only python3.
class NativeBuildGuardsTest < ActiveSupport::TestCase
  PIPELINE = File.expand_path("../compiled/pipeline", __dir__)

  NODE = <<~C
    struct sp_InstantRecord__Native__Node_s {
      sp_StrStrHash * iv_link_params;
      %s * iv_args;
      sp_StrStrHash *iv_props;
    };
  C

  setup { skip "python3 is not installed" unless system("python3", "--version", out: File::NULL, err: File::NULL) }

  test "a node whose hashes are all hashes of strings passes" do
    assert_equal [], guard("loose_node_fields", NODE % "sp_StrStrHash")
  end

  test "a node field the compiler typed loosely is named" do
    assert_equal ["args"], guard("loose_node_fields", NODE % "sp_StrPolyHash")
  end

  test "generated C with no node in it passes" do
    assert_equal [], guard("loose_node_fields", "int main(void) { return 0; }\n")
  end

  test "a certain TypeError is reported at the screen's line, once" do
    generated = <<~C
      #line 12 "app-src/app/screens/mailbox_screen.rb"
        sp_raise_cls("TypeError", "wrong argument type (expected Hash)");
        sp_raise_cls("TypeError", "wrong argument type (expected Hash)");
      #line 40 "app/models/message.rb"
        sp_raise_cls("TypeError", "wrong argument type (expected Hash)");
      #line 7 "app/screens/thread_screen.rb"
        sp_raise_cls("TypeError", "wrong argument type (expected String)");
    C

    assert_equal ["app/screens/mailbox_screen.rb:12"], guard("certain_type_errors", generated)
  end

  private

  def guard(name, generated)
    Tempfile.create("toolchain") do |toolchain|
      script = "import json, sys, build_native; print(json.dumps(build_native.#{name}(sys.stdin.read())))"
      out, err, status = Open3.capture3({"INSTANT_RECORD_TOOLCHAIN" => toolchain.path}, "python3", "-c", script, stdin_data: generated, chdir: PIPELINE)
      assert status.success?, err
      JSON.parse(out)
    end
  end
end
