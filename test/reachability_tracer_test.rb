require "test_helper"
require "instant_record/compiler"

# What one `render` call tells the tracer: the templates and partials to stage,
# the layouts to stage, and the warning when the name is only known at runtime.
class ReachabilityTracerTest < ActiveSupport::TestCase
  PARTIAL_WARNING = "Dynamic partial render; declare targets in include: { partials: [...] }."
  TEMPLATE_WARNING = "Dynamic template render; declare targets in include: { views: [...] }."
  EXPRESSION_WARNING = "Dynamic render expression; declare targets in include: { partials: [...] } or include: { views: [...] }."

  test "a first argument names a template in a controller and a partial in a view or helper" do
    ['render "row"', "render :row", 'render "row", status: :created'].each do |code|
      assert_render code, renders: [[:template, "row"]]
      assert_render code, in: :view, renders: [[:partial, "row"]]
      assert_render code, in: :helper, renders: [[:partial, "row"]]
    end
    assert_render 'render "größe/行"', renders: [[:template, "größe/行"]]
  end

  test "partial wins over template, template over action, and action over the first argument" do
    assert_render 'render "d", action: "c", template: "b", partial: "a"', renders: [[:partial, "a"]]
    assert_render 'render "d", action: :c, template: :b', in: :view, renders: [[:template, "b"]]
    assert_render 'render "d", action: :c', in: :view, renders: [[:template, "c"]]
    assert_render 'render({ "partial" => :a })', renders: [[:partial, "a"]]
  end

  test "a name known only at runtime warns, except for action, and falls through to nothing else" do
    assert_render 'render "d", partial: pick, template: "b"', warnings: [PARTIAL_WARNING]
    assert_render 'render "d", template: 3, action: "c"', warnings: [TEMPLATE_WARNING]
    assert_render 'render "d", action: pick'
    assert_render 'render "d", partial: nil', warnings: [PARTIAL_WARNING]
    ["render @row", "render row, status: :ok", "render 3", "render nil", 'render "a#{b}"', "render(*rows)"].each do |code|
      assert_render code, warnings: [EXPRESSION_WARNING]
      assert_render code, in: :view, warnings: [EXPRESSION_WARNING]
    end
  end

  test "a render of something other than a template adds nothing, not even its layout" do
    %w[json plain html inline body xml js file head nothing].each do |key|
      assert_render "render partial: pick, #{key}: value, layout: \"card\""
    end
    ["render", "render { 1 }", "render(&block)", "render status: :ok", "render(**options)"].each { |code| assert_render code }
  end

  test "a layout follows the target, as a partial from a view, a helper or beside partial, else as a layout" do
    assert_render 'render "row", layout: :card', renders: [[:template, "row"]], layouts: ["card"]
    assert_render 'render "row", layout: "card"', in: :view, renders: [[:partial, "row"], [:partial, "card"]]
    assert_render 'render layout: "card"', in: :helper, renders: [[:partial, "card"]]
    assert_render 'render partial: "row", layout: "card"', renders: [[:partial, "row"], [:partial, "card"]]
    assert_render 'render partial: pick, layout: "card"', renders: [[:partial, "card"]], warnings: [PARTIAL_WARNING]
    assert_render 'render row, layout: "card"', layouts: ["card"], warnings: [EXPRESSION_WARNING]
    ["false", "nil", "pick"].each { |value| assert_render "render layout: #{value}" }
  end

  test "a render call spread over several lines is recorded at its first line" do
    assert_render "render(\n  \"row\",\n  layout: \"card\"\n)", renders: [[:template, "row"]], layouts: ["card"]
    assert_render "render(\n  partial: pick\n)", warnings: [PARTIAL_WARNING]
    assert_render "render(\n  template: pick\n)", warnings: [TEMPLATE_WARNING]
    assert_render "render(\n  row\n)", warnings: [EXPRESSION_WARNING]
  end

  test "a name that is not valid text is taken as it is, and an option key that is not raises" do
    assert_render 'render "\xff", layout: "\xfe"', renders: [[:template, "\xff"]], layouts: ["\xfe"]
    assert_equal '"\u0000"', visit('render :"\0"').renders.first[:target].inspect
    assert_raises(EncodingError) { visit('render "row", "\xff" => 1') }
    assert_raises(EncodingError) { visit('render json: 1, "\xff" => 1') }
  end

  private

  def visit(code, place = :controller)
    visitor = InstantRecord::Compiler::ReachabilityTracer::FileVisitor.new(
      rel_path: "app/file.rb", is_view: place == :view, is_helper: place == :helper
    )
    parsed = Prism.parse("\n#{code}")
    assert parsed.success?, code
    parsed.value.accept(visitor)
    visitor
  end

  def assert_render(code, renders: [], layouts: [], warnings: [], **place)
    visitor = visit(code, place.fetch(:in, :controller))
    assert_equal renders.map { |kind, target| { kind: kind, target: target, line: 2 } }, visitor.renders, code
    assert_equal layouts.map { |target| { target: target, line: 2 } }, visitor.layouts, code
    expected = warnings.map do |message|
      { "level" => "warning", "kind" => "render", "file" => "app/file.rb", "line" => 2, "message" => message }
    end
    assert_equal expected, visitor.dynamic_warnings, code
  end
end
