require "test_helper"

# Provider calls belong to the Rails server. The compiled site runs in the
# visitor's browser, so nothing that names RubyLLM may be compiled into it:
# every such file has to be on the list carve.py leaves out of the build.
class CompiledCarveTest < ActiveSupport::TestCase
  CARVE = Rails.root.join("../compiled/pipeline/carve.py")

  test "no Ruby file that uses RubyLLM is carried into the compiled build" do
    removed = CARVE.read[/^REMOVE = \[(.*?)^\]/m, 1].scan(/"([^"]+)"/).flatten
    assert_includes removed, "config/initializers/ruby_llm.rb"

    carried = Dir.chdir(Rails.root) { Dir["{app,config,lib}/**/*.{rb,erb,rake}"] }
      .select { |path| File.read(path).match?(/RubyLLM|ruby_llm/) }
      .reject { |path| removed.any? { |entry| path == entry || path.start_with?("#{entry}/") } }

    assert_empty carried, "These would be compiled into the browser build. Add them to REMOVE in compiled/pipeline/carve.py."
  end
end
