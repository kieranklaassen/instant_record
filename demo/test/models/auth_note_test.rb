require "test_helper"

class AuthNoteTest < ActiveSupport::TestCase
  setup { AuthNote.seed_demo }

  def seen_by(id) = InstantRecord::SyncScope.visible(AuthNote, DemoAsker.new(nil, id)).pluck(:id).sort
  def written_by(id) = InstantRecord::SyncScope.writable(AuthNote, DemoAsker.new(nil, id)).pluck(:id).sort

  test "who is sent what" do
    assert_equal %w[auth-welcome], seen_by(nil)
    assert_equal %w[auth-cleo auth-lunch auth-welcome], seen_by("cleo")
    assert_equal %w[auth-ada auth-lunch auth-payroll auth-welcome], seen_by("ada")
  end

  test "not even an admin is sent another person's own note" do
    refute_includes seen_by("ada"), "auth-ben"
  end

  test "who may write what" do
    assert_empty written_by(nil)
    assert_equal %w[auth-ben auth-lunch], written_by("ben")
    assert_equal %w[auth-ada auth-payroll auth-welcome], written_by("ada")
  end

  test "seeding twice leaves six notes" do
    AuthNote.seed_demo

    assert_equal 6, AuthNote.count
  end
end
