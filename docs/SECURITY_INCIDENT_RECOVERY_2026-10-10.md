# Security incident recovery — 2026-10-10

- Repository: `ademisler/cipool-executor` (public)
- Original repository ID: `1368300808`
- Private, read-only original archive: `archive-cipool-executor-20261010-1368300808`
- New empty, non-template repository ID: `1413149830`
- Verified clean root commit: `4bacbc0e7a1efaf0453dddeb3f63af4f457b300b`
- Independently calculated rebuilt Git tree: `0005184df0166d0d91e503ca885f9d64b9339e91`
- Tracked source files: 21

## Provenance and validation

Only reviewed, tracked source was rebuilt from pinned archive data in disposable isolated infrastructure; none of the compromised Git object store, refs, hooks, ignored files, editor auto-run settings, malicious disguised font payloads or credentials was imported. One-root Git integrity, independent source tree SHA, GitHub ID and known malicious old blob SHA non-resolution checks passed. Original objects are retained solely in a private archived repository.

Across the recovery inventory, 712 JS/Python/Bash/JSON files plus 917 TypeScript/TSX/JSX source files passed static parsing checks. These are **not** end-to-end build, release or integration tests.

## Security restrictions and incomplete operational work

- GitHub Actions remains disabled pending review of workflows and safe fresh integration credentials.
- Do not reuse old secrets, cached dependencies or Git objects. Rotate compromised credentials with their providers.
- Reconcile local-only source changes and the persistent host Git object databases before marking production/developer checkouts synchronized.
- Older releases, issues, PRs and tags stay in restricted archival evidence unless explicitly reconstructed from independently reviewed source.
- Verify dependent runtime, CI and external deployments separately; do not equate static source checks with a working production release.

Restricted clean-room storage retains the clean bundle, SHA-256 manifests, forensic inventory and validation results. This record is a verifiable GitHub history-reset attestation, not complete service restoration.
