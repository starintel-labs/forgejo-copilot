question_identity(mara, 5).
question_identity(star, 1).
question_identity_validation(authenticated_user_endpoint, must_match_configured_login).
question_account_provisioning(existing_accounts, scoped_token_mint_without_password_reset).
question_token_scope('read:repository').
question_token_scope('write:issue').
question_token_scope('read:user').
question_mint_tool('scripts/mint_forgejo_identities.py').
question_policy_source(base_or_default_branch_commit, '.copilot').
question_policy_key(questions, enabled_boolean).
question_policy_key(question_mentions, configured_real_user_handles).
question_policy_key(question_mode, [mention, explicit]).
question_policy_key(question_context, [issues, prs]).
question_policy_key(question_access, [writers, anyone]).
question_authority(source_inspection_and_comment, no_repository_mutation).
question_budget(shared_with_reviews, daily_usd(5)).
question_idempotency([repository, issue, message_id, identity, body_revision]).
question_loop_prevention(configured_identity_and_bot_authors_excluded).
