/* Daemon entry point — deterministic unit tests for option parsing and
   the fail-fast environment gate, plus the selfhost check: the repo's
   own .copilot must parse into an enabling, tasks-on, auto-off config.

   No network, no sleeps: run/1 and the poll loop are exercised through
   the service-level suites (07) instead. */

:- use_module('loader.pl').
:- use_module(fcopilot(copilot_daemon)).
:- use_module(fcopilot(copilot_config)).
:- use_module(fcopilot(repo_ref)).
:- use_module(library(lists)).

:- begin_tests(daemon_cli).

test(once_by_default) :-
    copilot_daemon:cli_options(['--repo', 'o/r'], Options),
    option(forever(false), Options),
    option(repos(['o/r']), Options),
    option(poll_seconds(30), Options),
    option(state_dir('state/run'), Options).

test(forever_flag) :-
    copilot_daemon:cli_options(['--forever', '--repo', 'o/r'], Options),
    option(forever(true), Options).

test(last_mode_flag_wins) :-
    copilot_daemon:cli_options(['--forever', '--once', '--repo', 'o/r'], O1),
    option(forever(false), O1),
    copilot_daemon:cli_options(['--once', '--forever', '--repo', 'o/r'], O2),
    option(forever(true), O2).

test(repos_accumulate_in_order) :-
    copilot_daemon:cli_options(['--repo', 'o/a', '--repo', 'o/b'], Options),
    option(repos(Repos), Options),
    Repos == ['o/a', 'o/b'].

test(state_dir_and_poll_override_defaults) :-
    copilot_daemon:cli_options(['--state-dir', '/tmp/x', '--poll-seconds', '5',
                                '--repo', 'o/r'], Options),
    option(state_dir('/tmp/x'), Options),
    option(poll_seconds(5), Options).

test(model_step_parses_to_callable_term) :-
    copilot_daemon:cli_options(['--model-step', 'my_mod:my_step/4',
                                '--repo', 'o/r'], Options),
    option(model_step(my_mod:my_step/4), Options).

test(rejects_unknown_flag) :-
    \+ copilot_daemon:cli_options(['--bogus'], _).

test(rejects_repo_without_owner) :-
    \+ copilot_daemon:cli_options(['--repo', 'norepo'], _).

:- end_tests(daemon_cli).

:- begin_tests(daemon_env).

test(env_fail_fast_when_missing) :-
    with_forgejo_env(unset,
                     \+ copilot_daemon:env_options(
                             [repos(['o/r']), forever(false)], _)).

test(env_ok_with_credentials) :-
    with_forgejo_env(set,
                     copilot_daemon:env_options(
                         [repos(['o/r']), forever(false)], _)).

test(env_fail_fast_when_empty_repo_list) :-
    with_forgejo_env(set,
                     \+ copilot_daemon:env_options([repos([])], _)).

:- end_tests(daemon_env).

:- begin_tests(selfhost_config).

test(repo_copilot_is_enabling_tasks_on_auto_off) :-
    fcopilot_loader:repo_root(Root),
    format(atom(Path), '~w/.copilot', [Root]),
    read_file_to_string(Path, Text, []),
    copilot_config:parse(Text, Config),
    get_dict(enabled, Config, true),
    get_dict(tasks, Config, true),
    get_dict(auto, Config, Auto),
    Auto \== true.

test(repo_copilot_uses_fast_model) :-
    fcopilot_loader:repo_root(Root),
    format(atom(Path), '~w/.copilot', [Root]),
    read_file_to_string(Path, Text, []),
    copilot_config:parse(Text, Config),
    get_dict(model, Config, fast).

:- end_tests(selfhost_config).

% The env gate must be deterministic regardless of the caller's shell:
% both branches are forced explicitly and restored afterwards.
with_forgejo_env(Mode, Goal) :-
    (   getenv('FORGEJO_URL', SavedUrl) -> true ; SavedUrl = unset ),
    (   getenv('FORGEJO_TOKEN', SavedKey) -> true ; SavedKey = unset ),
    setup_call_cleanup(
        apply_forgejo_mode(Mode),
        Goal,
        restore_forgejo_env(SavedUrl, SavedKey)).

apply_forgejo_mode(set) :-
    setenv('FORGEJO_URL', 'http://127.0.0.1:9'),
    setenv('FORGEJO_TOKEN', 'test-token').
apply_forgejo_mode(unset) :-
    setenv('FORGEJO_URL', ''),
    setenv('FORGEJO_TOKEN', '').

restore_forgejo_env(unset, unset) :-
    unsetenv('FORGEJO_URL'),
    unsetenv('FORGEJO_TOKEN').
restore_forgejo_env(Url, Key) :-
    setenv('FORGEJO_URL', Url),
    setenv('FORGEJO_TOKEN', Key).
restore_forgejo_env(Url, unset) :-
    setenv('FORGEJO_URL', Url),
    unsetenv('FORGEJO_TOKEN').
restore_forgejo_env(unset, Key) :-
    unsetenv('FORGEJO_URL'),
    setenv('FORGEJO_TOKEN', Key).
