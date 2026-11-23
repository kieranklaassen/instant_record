require "test_helper"
require "instant_record/testing"
require "stringio"

class ChaosSimulatorTest < Minitest::Test
  def setup
    reset_instant_record_tables!
    @saved_synced = InstantRecord.synced_models.dup
    @saved_scope_from = InstantRecord.config.scope_from
  end

  def teardown
    InstantRecord.sync(*@saved_synced)
    InstantRecord.config.scope_from = @saved_scope_from
  end

  def test_seeded_chaos_converges_bit_for_bit_across_multiple_seeds
    io = StringIO.new
    reports = InstantRecord::Testing.run_chaos(
      seeds: [20261121, 20261122, 20261123],
      steps: 45,
      clients: 3,
      runtimes: "cruby",
      out: io
    )

    assert_equal 3, reports.size
    reports.each do |report|
      assert_equal 45, report.steps
      assert_equal 3, report.clients
      assert_operator report.stats[:bootstrap_aborts], :>=, 1
      assert_operator report.stats[:sync_passes], :>=, 1
      assert_includes io.string, "[PASS] seed=#{report.seed} converged bit-for-bit"
    end
  end

  def test_same_seed_produces_deterministic_operation_counts
    r1 = InstantRecord::Testing.run_chaos(seeds: [424242], steps: 30, clients: 3, runtimes: "cruby", out: StringIO.new).first
    r2 = InstantRecord::Testing.run_chaos(seeds: [424242], steps: 30, clients: 3, runtimes: "cruby", out: StringIO.new).first

    assert_equal r1.stats, r2.stats, "same SEED must drive the exact same deterministic chaos schedule"
    assert_equal r1.trace.size, r2.trace.size
  end
end
