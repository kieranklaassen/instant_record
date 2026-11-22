require "test_helper"
require "instant_record/compiler"
require "tmpdir"

# Provider calls belong to the Rails server. The compiled site runs in the
# visitor's browser, so nothing that names RubyLLM or server-only controllers
# may be staged into the compiled island by AppStage.
class CompiledCarveTest < ActiveSupport::TestCase
  test "no Ruby file that uses RubyLLM is staged into the compiled build" do
    Dir.mktmpdir do |dir|
      target = File.join(dir, "app-src")
      InstantRecord::Compiler::AppStage.stage(source: Rails.root, target: target, native: false)

      carried = Dir.chdir(target) { Dir["{app,config,lib}/**/*.{rb,erb,rake}"] }
        .select { |path| File.read(File.join(target, path)).match?(/RubyLLM|ruby_llm/) }

      assert_empty carried, "These files referencing RubyLLM were staged into the compiled island: #{carried.inspect}"
      refute File.exist?(File.join(target, "config/initializers/ruby_llm.rb"))
      refute File.exist?(File.join(target, "app/models/assistant/reply.rb"))
      refute File.exist?(File.join(target, "app/jobs/assistant/reply_job.rb"))
      refute File.exist?(File.join(target, "app/controllers/source_controller.rb"))
      refute File.exist?(File.join(target, "app/controllers/auth/sessions_controller.rb"))
      refute File.exist?(File.join(target, "app/controllers/slack/resets_controller.rb"))
      refute File.exist?(File.join(target, "app/controllers/email/sync_controller.rb"))
      refute File.exist?(File.join(target, "app/models/mailbox.rb"))
      refute File.exist?(File.join(target, "app/models/mail_shell.rb"))
    end
  end
end
