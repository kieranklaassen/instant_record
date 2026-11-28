require "test_helper"
require "instant_record/compiler"
require "fileutils"
require "pathname"
require "set"
require "tmpdir"

class AppStageTest < ActiveSupport::TestCase
  test "FileCopy.copy_tree copies nested files, dotfiles, large files, and preserves permissions" do
    Dir.mktmpdir do |dir|
      src = File.join(dir, "src")
      dst = File.join(dir, "nested/target/dst")
      FileUtils.mkdir_p(File.join(src, "bin"))
      FileUtils.mkdir_p(File.join(src, "assets/images"))

      File.write(File.join(src, "assets/.keep"), "")
      exec_src = File.join(src, "bin/run")
      File.write(exec_src, "#!/bin/sh\necho ok\n")
      File.chmod(0o755, exec_src)

      priv_src = File.join(src, "secret.txt")
      File.write(priv_src, "private\n")
      File.chmod(0o600, priv_src)

      large_bytes = ("0123456789abcdef" * 20_000).b # 320 KB (> SMALL_FILE_THRESHOLD)
      File.binwrite(File.join(src, "assets/images/big.bin"), large_bytes)

      InstantRecord::Compiler::FileCopy.copy_tree(src, dst)

      assert_equal "", File.read(File.join(dst, "assets/.keep"))
      assert_equal "#!/bin/sh\necho ok\n", File.read(File.join(dst, "bin/run"))
      assert_equal File.stat(exec_src).mode & 0o777 & ~File.umask, File.stat(File.join(dst, "bin/run")).mode & 0o777
      assert_equal File.stat(priv_src).mode & 0o777 & ~File.umask, File.stat(File.join(dst, "secret.txt")).mode & 0o777
      assert_equal large_bytes, File.binread(File.join(dst, "assets/images/big.bin"))
    end
  end

  test "FileCopy.copy_tree filters ignore names at every nesting level and overwrites existing targets" do
    Dir.mktmpdir do |dir|
      src = File.join(dir, "src")
      dst = File.join(dir, "dst")
      FileUtils.mkdir_p(File.join(src, "app/node_modules/pkg"))
      FileUtils.mkdir_p(File.join(src, "app/models"))
      FileUtils.mkdir_p(File.join(src, "test"))
      File.write(File.join(src, "app/node_modules/pkg/index.js"), "ignored\n")
      File.write(File.join(src, "test/foo_test.rb"), "ignored\n")
      File.write(File.join(src, "app/models/note.rb"), "short\n")
      File.write(File.join(src, "app/models/build"), "ignored file\n")

      FileUtils.mkdir_p(File.join(dst, "app/models"))
      File.write(File.join(dst, "app/models/note.rb"), "much longer previous content\n" * 10)

      InstantRecord::Compiler::FileCopy.copy_tree(src, dst, ignore: %w[build node_modules test])

      assert_equal "short\n", File.read(File.join(dst, "app/models/note.rb"))
      refute File.exist?(File.join(dst, "app/node_modules"))
      refute File.exist?(File.join(dst, "test"))
      refute File.exist?(File.join(dst, "app/models/build"))
    end
  end

  test "FileCopy.copy_tree handles symlinked files, diamond symlinks, cycles, and caller visited sets" do
    Dir.mktmpdir do |dir|
      src = File.join(dir, "src")
      shared = File.join(dir, "shared")
      skipped = File.join(dir, "skipped")
      ext_file = File.join(dir, "external.rb")
      dst = File.join(dir, "dst")

      FileUtils.mkdir_p(src)
      FileUtils.mkdir_p(shared)
      FileUtils.mkdir_p(skipped)
      File.write(File.join(shared, "util.rb"), "# util\n")
      File.write(File.join(skipped, "omit.rb"), "# omit\n")
      File.write(ext_file, "# external\n")

      File.symlink(ext_file, File.join(src, "linked_file.rb"))
      File.symlink(shared, File.join(src, "branch_a"))
      File.symlink(shared, File.join(src, "branch_b"))
      File.symlink(skipped, File.join(src, "already_visited"))
      File.symlink(src, File.join(shared, "loop_to_root"))

      InstantRecord::Compiler::FileCopy.copy_tree(
        src,
        dst,
        visited: Set[Pathname(skipped).realpath]
      )

      assert_equal "# external\n", File.read(File.join(dst, "linked_file.rb"))
      refute File.symlink?(File.join(dst, "linked_file.rb"))
      assert_equal "# util\n", File.read(File.join(dst, "branch_a/util.rb"))
      assert_equal "# util\n", File.read(File.join(dst, "branch_b/util.rb"))
      refute File.exist?(File.join(dst, "branch_a/loop_to_root"))
      refute File.exist?(File.join(dst, "already_visited"))
    end
  end

  test "FileCopy.copy_tree refuses same-file copies without truncating small or large files" do
    Dir.mktmpdir do |dir|
      src = File.join(dir, "src")
      dst = File.join(dir, "dst")
      FileUtils.mkdir_p(src)
      FileUtils.mkdir_p(dst)

      large_bytes = ("0123456789abcdef" * 20_000).b # 320 KB (> SMALL_FILE_THRESHOLD)
      small_bytes = "small payload\n"

      big_dst = File.join(dst, "big.bin")
      small_dst = File.join(dst, "small.txt")
      File.binwrite(big_dst, large_bytes)
      File.binwrite(small_dst, small_bytes)

      # Symlink from src pointing directly to existing >256 KB file in dst.
      File.symlink(big_dst, File.join(src, "big.bin"))
      err = assert_raises(ArgumentError) do
        InstantRecord::Compiler::FileCopy.copy_tree(src, dst)
      end
      assert_match(/same file:/, err.message)
      assert_equal large_bytes, File.binread(big_dst)

      # Self-copy of a directory containing a small file raises without truncating.
      File.delete(File.join(src, "big.bin"))
      File.symlink(small_dst, File.join(src, "small.txt"))
      err = assert_raises(ArgumentError) do
        InstantRecord::Compiler::FileCopy.copy_tree(src, dst)
      end
      assert_match(/same file:/, err.message)
      assert_equal small_bytes, File.binread(small_dst)
    end
  end

  test "FileCopy.copy_tree raises Errno::ENOENT on broken symlinks unless ignored" do
    Dir.mktmpdir do |dir|
      src = File.join(dir, "src")
      dst = File.join(dir, "dst")
      FileUtils.mkdir_p(src)
      File.write(File.join(src, "ok.rb"), "ok\n")
      File.symlink(File.join(dir, "missing_target"), File.join(src, "broken_link"))

      assert_raises(Errno::ENOENT) do
        InstantRecord::Compiler::FileCopy.copy_tree(src, dst)
      end

      InstantRecord::Compiler::FileCopy.copy_tree(src, File.join(dir, "dst_ignored"), ignore: ["broken_link"])
      assert_equal "ok\n", File.read(File.join(dir, "dst_ignored/ok.rb"))
      refute File.exist?(File.join(dir, "dst_ignored/broken_link"))
    end
  end

  test "AppStage refuses path traversal, sibling prefix tricks, and absolute paths outside app root" do
    Dir.mktmpdir do |dir|
      app_root = File.join(dir, "app")
      sibling_root = File.join(dir, "app_evil")
      target = File.join(dir, "staged")
      nested_target = File.join(app_root, "tmp/staged")
      FileUtils.mkdir_p(app_root)
      FileUtils.mkdir_p(sibling_root)
      FileUtils.mkdir_p(nested_target)
      File.write(File.join(dir, "secret.txt"), "secret\n")
      File.write(File.join(sibling_root, "pwn.rb"), "evil\n")
      File.write(File.join(app_root, "inside.rb"), "ok\n")
      nested_file = File.join(nested_target, "already.rb")
      File.write(nested_file, "nested\n")

      [
        "../secret.txt",
        "../app_evil/pwn.rb",
        File.join(sibling_root, "pwn.rb"),
        File.join(app_root, "inside.rb"),
        ".",
        "",
        "sub/../../secret.txt"
      ].each do |bad_rel|
        err = assert_raises(InstantRecord::Compiler::BuildError, "expected rejection for #{bad_rel.inspect}") do
          InstantRecord::Compiler::AppStage.send(:copy_file_if_present, Pathname(app_root), Pathname(target), bad_rel)
        end
        assert_equal "Refusing to stage path outside app root: #{bad_rel.inspect}", err.message
      end

      err = assert_raises(InstantRecord::Compiler::BuildError) do
        InstantRecord::Compiler::AppStage.send(:copy_file_if_present, Pathname(app_root), Pathname(nested_target), nested_file)
      end
      assert_equal "Refusing to stage path outside app root: #{nested_file.inspect}", err.message
    end
  end

  test "AppStage.stage replaces existing target, applies overlay, handles symlinks, drops unsynced FKs, and requires schema.rb" do
    Dir.mktmpdir do |dir|
      app_root = File.join(dir, "app")
      overlay = File.join(dir, "overlay")
      target = File.join(dir, "staged")
      manifest_path = File.join(dir, "out/nested/instant_record.manifest.json")
      external_helper = File.join(dir, "shared_helper.rb")

      FileUtils.mkdir_p(File.join(app_root, "app/models"))
      FileUtils.mkdir_p(File.join(app_root, "app/controllers"))
      FileUtils.mkdir_p(File.join(app_root, "app/helpers"))
      FileUtils.mkdir_p(File.join(app_root, "config"))
      FileUtils.mkdir_p(File.join(app_root, "db"))
      FileUtils.mkdir_p(File.join(overlay, "models"))

      File.write(external_helper, "module SharedHelper; end\n")
      File.symlink(external_helper, File.join(app_root, "app/helpers/shared_helper.rb"))
      File.write(File.join(app_root, "Gemfile"), "source 'https://rubygems.org'\n")
      File.write(File.join(app_root, "config/routes.rb"), "Rails.application.routes.draw { root 'tasks#index' }\n")
      File.write(File.join(app_root, "app/models/task.rb"), "class Task < ApplicationRecord\n  include InstantRecord::Syncable\nend\n")
      File.write(File.join(app_root, "app/models/project.rb"), "class Project < ApplicationRecord\n  include InstantRecord::Syncable\nend\n")
      File.write(File.join(app_root, "app/controllers/tasks_controller.rb"), "class TasksController < ApplicationController\n  def index; end\nend\n")
      File.write(File.join(overlay, "models/task.rb"), "class Task < ApplicationRecord\n  include InstantRecord::Syncable\n  # overlaid\nend\n")

      # Missing db/schema.rb raises BuildError.
      err = assert_raises(InstantRecord::Compiler::BuildError) do
        InstantRecord::Compiler::AppStage.stage(source: app_root, target: target)
      end
      assert_match(/needs db\/schema\.rb/, err.message)

      File.write(File.join(app_root, "db/schema.rb"), <<~RUBY)
        ActiveRecord::Schema[8.1].define(version: 1) do
          add_foreign_key "tasks", "users"
          add_foreign_key "tasks", "projects"
        end
      RUBY

      # Stale file in an existing target directory is wiped cleanly.
      FileUtils.mkdir_p(target)
      File.write(File.join(target, "stale.txt"), "old\n")

      result = InstantRecord::Compiler::AppStage.stage(
        source: app_root,
        target: target,
        overlay_dir: overlay,
        manifest_path: manifest_path
      )

      refute File.exist?(File.join(target, "stale.txt"))
      assert_equal "class Task < ApplicationRecord\n  include InstantRecord::Syncable\n  # overlaid\nend\n", File.read(File.join(target, "app/models/task.rb"))
      assert_equal "module SharedHelper; end\n", File.read(File.join(target, "app/helpers/shared_helper.rb"))
      staged_schema = File.read(File.join(target, "db/schema.rb"))
      refute_includes staged_schema, 'add_foreign_key "tasks", "users"'
      assert_includes staged_schema, 'add_foreign_key "tasks", "projects"'
      assert File.file?(manifest_path)
      assert_equal result.manifest.to_h, InstantRecord::Compiler::Manifest.read(manifest_path).to_h

      # Schema without any add_foreign_key lines takes the fast-skip path unchanged.
      plain_schema = "ActiveRecord::Schema[8.1].define(version: 1) do\nend\n"
      File.write(File.join(app_root, "db/schema.rb"), plain_schema)
      InstantRecord::Compiler::AppStage.stage(source: app_root, target: target)
      assert_equal plain_schema, File.read(File.join(target, "db/schema.rb"))
    end
  end
end
