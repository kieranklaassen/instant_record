# Idempotent — safe to run repeatedly. The Slack demo's reset endpoint reuses
# the same routine, so "reset" and "fresh install" are the same state.
Slack::Seeds.apply
