require "test_helper"
require "instant_record/compiler"

# The two checks NativeBuild makes of the C the compiler wrote, with canned C:
# they need no toolchain and run directly in Ruby.
class NativeBuildGuardsTest < ActiveSupport::TestCase
  NODE = <<~C
    struct sp_InstantRecord__Native__Node_s {
      sp_StrStrHash * iv_link_params;
      %s * iv_args;
      sp_StrStrHash *iv_props;
    };
  C

  test "a node whose hashes are all hashes of strings passes" do
    assert_equal [], InstantRecord::Compiler::NativeBuild.loose_node_fields(NODE % "sp_StrStrHash")
  end

  test "a node field the compiler typed loosely is named" do
    assert_equal ["args"], InstantRecord::Compiler::NativeBuild.loose_node_fields(NODE % "sp_StrPolyHash")
  end

  test "generated C with no node in it passes" do
    assert_equal [], InstantRecord::Compiler::NativeBuild.loose_node_fields("int main(void) { return 0; }\n")
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

    assert_equal ["app/screens/mailbox_screen.rb:12"], InstantRecord::Compiler::NativeBuild.certain_type_errors(generated)
  end
end
