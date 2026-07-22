# Residual Review Findings — feat/swiss-slack-demo

Source: `ce-code-review` (mode:agent) run during the LFG pipeline for the Swiss Slack demo branch, reviewed against `docs/plans/2026-07-22-001-feat-slack-demo-multi-app-plan.md`.

## Residual Review Findings

- P2 · `demo/app/helpers/slack_helper.rb:7-11` · Same-origin reset runs in the browser runtime, not the server — [#1](https://github.com/kieranklaassen/instant_record/issues/1)
- P2 · `lib/instant_record/syncable.rb:46` · Cascaded destroys during client-mutation apply are never change-logged — [#2](https://github.com/kieranklaassen/instant_record/issues/2)
- P3 · `demo/app/helpers/slack_helper.rb:10` · Reset URL derivation hardcodes the default mount path — [#3](https://github.com/kieranklaassen/instant_record/issues/3)
- P3 · `demo/app/jobs/slack/fake_reply_job.rb:24-33` · Pending FakeReplyJob can post a stray reply after reset — [#4](https://github.com/kieranklaassen/instant_record/issues/4)

Applied during the pipeline (not residual): the reset trigger now reloads the page directly when no service worker controls it (review finding P3, fixed in-branch).

No `settled_conflict` findings; no settled-decision conflicts were flagged during implementation.
