# pragmatic-claude docs

How to use and extend this Claude Code config. The [README](../README.md) covers install plus a one-line summary of every command and skill. These pages go deeper: real workflows end to end, how to add your own commands, skills, and hooks, and how the launcher, hooks, memory, and model routing work underneath.

Read them in order, or jump to what you need.

## Workflows

- [01 Plan and Implement](01-plan-and-implement.md): design a feature with `/scope`, then build it with `/implement`.
- [02 Review and PR Flow](02-review-and-pr-flow.md): commit, review with `/quick-review` or `/deep-review`, then work through feedback with `/address-pr-comments`.
- [03 Decisions and Memory](03-decisions-and-memory.md): record architectural choices with `/adr`, and build durable project knowledge with `/learn-project`.

## Extending

- [04 Authoring Commands, Skills, and Hooks](04-authoring-commands-skills-hooks.md): add your own behavior, with copy-paste templates grounded in the real formats.

## Internals

- [05 Internals: Launcher and Hooks](05-internals-launcher-and-hooks.md): the `cc` launcher, the worktree engine, and the hook lifecycle.
- [06 Internals: Model Routing and Memory](06-internals-memory-and-routing.md): how the session model gets picked, and the two-level memory graph.
