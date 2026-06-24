---
name: engineering-standards
description: Use when working on pull requests, planning testing approach, or thinking about deployment. Covers the team engineering process across PR readiness criteria, size limits, review comment conventions, testing requirements (unit/integration/E2E), mocking guidelines, incremental delivery, and deployment flow.
---

# Engineering Standards

Team engineering standards for pull requests, testing, design, and deployment. RFC 2119 keywords (MUST, SHOULD, etc.) carry their standard meanings.

## Pull Requests

### Readiness

A PR MUST meet these criteria before requesting review:

- CI is fully passing.
- Automated tests are included for the change.
- The author has self-reviewed the diff.
- The description explains the "why", not just the "what".
- Any intentional technical debt is documented in the description with justification.

### Size

- PRs SHOULD be under 500 changed lines (additions + deletions).
- PRs MUST NOT exceed 1000 changed lines without explicit justification.
- Large changes SHOULD be split into logical units (e.g., one PR for the data layer, another for the service layer).

### Review Comments

- Review comments SHOULD use Conventional Comments format with labels and decorations.
- Blocking comments are for issues that MUST be resolved before merge: quality gaps, undocumented tech debt, security or data integrity concerns, missing tests, or architectural issues affecting future maintenance.
- Blocking comments SHOULD be treated as opportunities for discussion, not hard stops. Valid resolutions: fix immediately, create a follow-up ticket, document the limitation, agree the concern is out of scope, or escalate to a design discussion.
- Non-blocking feedback SHOULD be framed as suggestions: "one thing we could do..." or "worth considering...".
- Reviewers SHOULD prioritise re-reviews and PRs closest to completion over new PRs (pull work to the right).

### Review Turnaround

- Initial reviews SHOULD be completed within 24 hours.
- Re-reviews (after author addresses feedback) SHOULD be completed within 4 hours.

## Automated Testing

### Test Types

| Type | What it tests | External dependencies |
|---|---|---|
| Unit tests | Business logic of a specific function or class | None |
| Integration tests | Service and data layer behaviour | Database |
| API/container tests | API behaviour with real database, stubbed externals | API + database |
| E2E tests | Full user flows | Full environment |

### Requirements

- All code changes MUST include appropriate automated tests.
- Unit tests SHOULD focus on error handling and edge cases that are difficult to exercise in higher-level tests.
- Integration tests MUST be isolated: each test creates its own data and MUST NOT rely on shared seed data.
- Code SHOULD be structured so it could achieve high unit test coverage without requiring refactoring, even if 100% coverage is not required.
- When implementing new functionality, TDD (red/green/refactor) SHOULD be used: write a failing test first, then minimal implementation to pass, then refactor. This prevents tests that are tautologically coupled to the implementation.
- Coverage thresholds MUST NOT be decreased. If changes increase coverage, thresholds SHOULD be raised.
- CI MUST pass before a PR is eligible for review.

### Mocking

- Mock only where necessary, as close to the application boundary as possible.
- Prefer dependency injection over global mocking for easier-to-understand tests.
- For domain services: spy on the interface and verify call parameters; do NOT mock the database tables owned by another service.

## Manual Testing

- Changes MUST be manually verified before merge, as a complement to automated testing.
- If a scenario can be covered by an automated test, it SHOULD be.
- Database migration PRs: the query SHOULD be verified by converting it to a SELECT and running it against production data first.

## Incremental Delivery

- Work MUST be delivered incrementally, not in a single large release.
- Feature flags MUST be used (where available) to enable safe, incremental rollout.
- Each work unit SHOULD be independently deliverable and testable.

## Deployment

- Deployment path: merge to main -> automated post-merge checks -> manual approval -> deploy.
- Engineers MUST monitor their changes after deployment for errors, performance regressions, and unexpected behaviour.
