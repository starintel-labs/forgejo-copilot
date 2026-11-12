agent_runtime(pi, '1.5.2', 'deploy/pi.Dockerfile').
agent_tool(read).
agent_tool(bash).
sandbox_boundary(nonroot_uid, 1000).
sandbox_boundary(capabilities, none).
sandbox_boundary(workspace, readonly_snapshot).
sandbox_boundary(rootfs, readonly).
sandbox_boundary(network, internal_host_isolated_bridge).
sandbox_boundary(credentials, absent).
sandbox_boundary(docker_socket, absent).
sandbox_boundary(context_discovery, disabled).
sandbox_boundary(extensions_and_mcp, disabled).
sandbox_limit(cpu, 1).
sandbox_limit(memory_mb, 1024).
sandbox_limit(pids, 128).
sandbox_limit(timeout_seconds, 240).
isolation_check('python3 scripts/check_pi_deployment.py --repo nsaspy/forgejo-copilot-pi-test').
