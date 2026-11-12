component(pi_review_controller, 'scripts/pi_review_service.py', trusted_host).
component(pi_review_installer, 'scripts/deploy_pi_reviews.py', trusted_host).
component(pi_review_live_check, 'scripts/check_pi_deployment.py', trusted_host).
review_enablement(base_commit, '.copilot', enabled_true).
review_scope(explicit_repository_allowlist, open_pull_requests).
review_authority(comment_only, no_push_approve_or_merge).
review_manual_permission(write).
review_manual_permission(admin).
review_idempotency([repository, pull_number, head_sha, base_sha, trigger]).
review_recovery(sqlite_ledger, remote_comment_marker).
review_runtime_state('~/.local/state/forgejo-copilot').
