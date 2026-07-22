# Idempotent — safe to run repeatedly. The Slack demo's reset endpoint reuses
# the same routine, so "reset" and "fresh install" are the same state.
#
# Server runtime only: the browser runtime also runs seeds on boot
# (DatabaseTasks.prepare_all in the service worker), but there every create is
# a local write that lands in the outbox — a fresh client would replay all the
# seed rows at the server as client mutations. Browsers receive seed data via
# the downstream change-log sync instead.
Slack::Seeds.apply unless InstantRecord.browser?
