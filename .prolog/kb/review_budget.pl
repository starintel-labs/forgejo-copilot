budget_provider(openrouter, dedicated_child_key).
budget_limit(usd, 5, daily_utc, includes_byok).
budget_local_reservation(cents, 25, per_upstream_attempt, no_refund).
budget_local_daily_max(cents, 500).
budget_model('openai/gpt-4.1-mini').
budget_price_ceiling(input_usd_per_million, 1).
budget_price_ceiling(output_usd_per_million, 4).
budget_request_limit(text_bytes, 200000).
budget_request_limit(output_tokens, 4096).
budget_guard('deploy/gateway.py', price_and_key_checked_before_reservation).
budget_catalog_optional_fee(web_search, not_invoked_by_function_only_tools).
budget_security(management_key, host_only).
budget_security(child_key, gateway_only).
