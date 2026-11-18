# Combined demo results

The combined branch builds on the responsiveness branch’s persistent Wasm reactor and SQLite connection. Incoming polls and outbound writes run asynchronously. Rails acknowledgments are applied through the existing Ruby sync code. If a local edit arrives while a batch is in flight, the worker retries the durable mutation IDs before applying its result.

The combined build had the repaired Sync inspector active throughout measurement. The combined build and the unmodified reactor were measured in three alternating pairs using the seven-click Chrome workload from commit `04fa224`. Each run used five fresh profiles and an isolated Rails server backed by PostgreSQL 18. The other two columns come from the previous comparison. Results are medians of run medians, in milliseconds unless indicated.

| Interaction | Baseline | Latency branch | Reactor branch | Combined |
| --- | ---: | ---: | ---: | ---: |
| Seven-click score | 17.3 | 12.5 | 4.1 | 3.9 |
| Channel switch | 15.6 | 21.3 | 9.3 | 9.1 |
| Slack send | 20.6 | 13.2 | 3.2 | 3.5 |
| Open thread | 14.6 | 15.9 | 2.7 | 2.9 |
| Thread reply | 20.9 | 9.4 | 2.7 | 2.1 |
| Todo create | 15.7 | 9.5 | 2.6 | 2.6 |
| Todo toggle | 17.6 | 10.2 | 3.9 | 3 |
| Todo delete | 15.5 | 9.2 | 3.7 | 3.7 |
| Slack reload | 176.6 | 167.5 | 135.1 | 134.7 |
| First visit | 258.9 | 251.9 | 203.6 | 204 |
| First-visit gzip (bytes) | 2,486,051 | 2,491,836 | 1,637,386 | 1,638,528 |

The seven-click score is the mean of the seven interaction medians within each run. For the combined build, its three values were 3.6, 3.9, 3.9 ms. The reactor reference in the same comparison recorded 3.7, 4.1, 4.1 ms. The workload measures the time until the expected DOM change. Warm and cold boot use the first frame with a visible conversation row. The supplied baseline was 17.2 ms and the independent baseline rerun in the table measured 17.3 ms.

## When the first write acknowledgment is delayed by 400 ms

| Branch | Second Todo visible | Accepted and rejected cases |
| --- | ---: | ---: |
| Latency | 12 ms | 6/6 |
| Reactor | 410 ms | 6/6 |
| Combined | 3 ms | 6/6 |

Every final benchmark run passed all 12 behavior checks. The additional overlap test kept the first response open while editing the same Todo, then confirmed its final state by bootstrapping a fresh browser context. It also checked a rejected create followed by an accepted one. A separate browser test checked boot history, clearing the worker log, the local flow diagram, and the Offline and Slow switches. A fresh client confirmed an offline edit stayed out of Rails across reload and arrived once on reconnection. The Slow switch imposed at least 2,000 ms on the actual outgoing request while local editing remained responsive. A peer edit also stayed hidden while Offline was selected and appeared with an incoming event in the log on reconnection. The full Rails demo suite passed 108 tests and 425 assertions.
