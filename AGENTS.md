# AGENTS.md

Guide for agents and humans working in this repo. `CLAUDE.md` is a symlink to
this file.

## Workflow

No pull requests. Kieran's word of 2026-11-18.

1. Branch from `main` (`feat/…`, `fix/…`, `chore/…`) and commit there. Never
   commit on `main` itself.
2. Merge `origin/main` into the branch and run the tests on that result:
   `bundle exec rake test` for the gem, and `cd demo && bin/rails test` when
   the demo changed.
3. When they pass, merge the branch into `main` with a merge commit
   (`git merge --no-ff`) and push `main`.
4. Delete the branch, locally and on the remote.

If tests fail, a merge conflicts in a way you can't resolve cleanly, or the
push is refused, stop and say so. A pull request is no way around it.
