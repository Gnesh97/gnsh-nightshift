# S20 Sprint Report - Demand, Heat, and Vice

- Sprint: S20
- Completed tasks: NS-200 bounded heat domain/service, NS-201 configurable vice-risk resolver, and NS-202 demand-to-heat feedback.
- New files: config/heat.lua, config/vice.lua, config/demand_heat_feedback.lua, server/domain/heat.lua, server/services/heat_service.lua, server/services/vice_service.lua, server/services/demand_heat_feedback_service.lua, server/jobs/heat_decay_job.lua, server/dev/s20_smoke.lua, and S20 contract tests.
- Heat contract: Server events can increment optional per-player heat and per-district pressure. Event keys are replay-safe, values are clamped to configured bounds, server timestamps are authoritative, and scheduled decay runs at a bounded interval rather than per frame.
- Vice contract: Risk combines district pressure, NPC risk archetype, and booking context into a bounded explainable score. The feature is opt-in and police/dispatch hooks run only when explicitly configured thresholds and providers are present; no random omniscient notification is generated.
- Feedback contract: High street pressure lowers street opportunity, private availability remains configurable, and demand/supply/heat pricing modifiers are clamped to stable minimum/maximum multipliers. Lower pressure recovers normally after decay.
- Configuration and bootstrap changes: Added fail-fast validation/schema entries, feature flags, event-bus wiring, demand heat resolver integration, lifecycle-managed decay job, and development-only smoke commands. No server.cfg edits are required.
- Automated checks: lua tests/run.lua, luac -p over all Lua files, and S20 contract tests pass. Coverage includes heat clamps, event replay, decay scheduling, risk explanation/dispatch gating, oversupply, recovery, and invalid configuration.
- Security and performance: Inputs and configuration are bounded; heat state is server-owned; event subscriptions use committed domain events; decay is one scheduled bounded loop with no per-player or per-frame threads.
- Live verification: FXServer smoke remains deployment-specific. After the resource is restarted, use the emitted S20 command help/results; vice is disabled by default until its feature/config flag is explicitly enabled.
- Exit Gate result: PASS for S20 heat, vice risk, demand feedback, and scheduled decay contracts.
