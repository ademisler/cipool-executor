# CI Pool Executor

Public, credential-free CircleCI executor bootstrap for CI Pool.

The pipeline receives only a one-time CI Pool runner ticket and broker URL. The executor exchanges that ticket for a short-lived lease, checks out the exact target commit with a short-lived GitHub App token, redacts the remote, drops the token, and then executes the job command authorized by CI Pool.

No provider token, GitHub App private key, deployment credential, or persistent repository credential belongs in this repository.
