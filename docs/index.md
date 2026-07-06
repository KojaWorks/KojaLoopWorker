# Documentation index

Read the doc whose situation matches yours.

| Doc | Read it when… |
| --- | --- |
| [../DESIGN.md](../DESIGN.md) | You need how LoopWorker works: the Manager/Worker split, host mode, the slot pool (hot/cold, weighted budget), the reconcile→spawn→reap loop, the `.loopworker/` contract, and the rationale behind each load-bearing decision. The architecture source of truth. |
| [../README.md](../README.md) | You want the operator's view: what it is, the north star, quickstart, host setup, the CLI, stopping/draining. |
| [dev_guide.md](dev_guide.md) | You're developing or testing LoopWorker: the venv, running the suite, how the tests mock the fleet, single-project mode for local runs, the dashboard, and the live-host gotchas (worktree foot-gun, Docker/OrbStack, memory). |
| The **Roadmap** in Patch, filtered to KojaLoopWorker | You want the forward backlog — open work, the self-healing cluster, priorities. LoopWorker plans its own development in the shared Patch roadmap (`project = KojaLoopWorker`); see the backlog section in [../AGENTS.md](../AGENTS.md). |
