# Documentation index

Read the doc whose situation matches yours.

| Doc | Read it when… |
| --- | --- |
| [../DESIGN.md](../DESIGN.md) | You need how LoopWorker works: Manager and credential-free Worker, the separate backlog and forge seams, card states and trust, the worker lifecycle and outcome file, waiting for CI and fix rounds, reconcile, host config and on-disk state. The architecture source of truth. |
| [glossary.md](glossary.md) | You're naming something, or two words seem to mean the same thing. One term per concept; the glossary wins. |
| [project-contract.md](project-contract.md) | You're making a project LoopWorker-compatible: the `.loopworker/` files, the script environment, `manifest.toml` keys, hot vs cold, pinned toolchains. |
| [behavior-spec.md](behavior-spec.md) | You're changing a component and need every behavior it must keep, with row ids (`B12`) to cite in tests and commits, and where each came from. |
| [../README.md](../README.md) | You want the operator's view: install, configuration, secrets, the GitLab trust model and labels, the service, doctor, status, pause and stopping. |
| [dev_guide.md](dev_guide.md) | You're developing or testing LoopWorker: SwiftPM build and test, how the fakes stand in for tmux, git, processes and HTTP, running a real Manager end to end against a sandbox with a stub `claude`, and the live-host gotchas. |
| [distribution.md](distribution.md) | Superseded by DESIGN.md "Distribution": the Homebrew release, the launchd service and doctor in brief. |
| The **Roadmap** in Patch, filtered to KojaLoopWorker | You want the forward backlog — open work, the self-healing cluster, priorities. LoopWorker plans its own development in the shared Patch roadmap (`project = KojaLoopWorker`); see the backlog section in [../AGENTS.md](../AGENTS.md). |
