# Documentation index

Read the doc whose situation matches yours.

| Doc | Read it when… |
| --- | --- |
| [../DESIGN.md](../DESIGN.md) | You need how LoopWorker works: Manager and powerless Worker, the separate backlog and forge seams, card states and trust, the worker lifecycle and outcome file, reconcile, host config and on-disk state. The architecture source of truth. |
| [glossary.md](glossary.md) | You're naming something, or two words seem to mean the same thing. One term per concept; the glossary wins. |
| [behavior-spec.md](behavior-spec.md) | You're implementing or testing a component of the Swift port: every behavior it must have, with the Python origin of each. |
| [../README.md](../README.md) | You want the operator's view: what it is, the north star, quickstart, host setup, the CLI, stopping/draining. |
| [dev_guide.md](dev_guide.md) | You're developing or testing LoopWorker: the venv, running the suite, how the tests mock the fleet, single-project mode for local runs, the dashboard, and the live-host gotchas (worktree foot-gun, Docker/OrbStack, memory). |
| [distribution.md](distribution.md) | You're working on how LoopWorker ships: the Mac menu-bar app, the Linux service, the status/readiness contract every shell consumes, Koja Works presence, and the packaging-not-rewrite principle. The plan for making it a releasable product. |
| The **Roadmap** in Patch, filtered to KojaLoopWorker | You want the forward backlog — open work, the self-healing cluster, priorities. LoopWorker plans its own development in the shared Patch roadmap (`project = KojaLoopWorker`); see the backlog section in [../AGENTS.md](../AGENTS.md). |
