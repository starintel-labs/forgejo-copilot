component(implementation_worker, 'scripts/copilot_worker.py', trusted_host).
component(implementation_job_store, 'scripts/copilot_jobs.py', sqlite).
implementation_authority(default_branch_policy_and_current_writer_permission).
implementation_sandbox(writable_workspace, bounded_tmpfs).
implementation_sandbox(source_input, readonly_host_snapshot).
implementation_checks(network_none, readonly_artifact, actual_process_exit).
implementation_publication(copilot_branch, whole_commit_artifact_digest_match).
implementation_prohibition(approve_merge_deploy).
implementation_checkpoint(provider_failure_timeout_cancel, validated_partial_workspace).
implementation_retry(increment_revision, preserve_task_identity).
implementation_recovery(uncertain_commit, compare_remote_snapshot_before_rewrite).
docker_tmpfs_export(container_tar, archive_api_omits_mount_contents).
docker_orphan_role(controller, review).
docker_orphan_role(worker, task).
docker_orphan_role(worker, 'task-check').
docker_orphan_role(discord_chat, discord).
verification_command(implementation_unit, 'python3 -B -m unittest discover -s test -p test_copilot_worker.py -v').
verification_command(implementation_docker, 'env COPILOT_DOCKER_TESTS=1 python3 -B -m unittest discover -s test -p test_worker_docker.py -v').
