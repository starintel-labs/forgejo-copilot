:- module(copilot_daemon,
          [ cli_options/2,
            env_options/2,
            run/1,
            daemon_main/1
          ]).

/** <module> Daemon entry point

Long-running service wrapper around service:poll_once/1. There is no
inbound network surface: the daemon polls the configured Forgejo with a
cursor, resumes any paused (crashed) runs on start, and keeps polling
forever (or once) with exceptions caught per cycle so one bad cycle
never kills the process.

Command line:

    swipl -s bin/copilot-service.pl -- [--once|--forever]
                                        --repo Owner/Name (repeatable)
                                        [--state-dir Dir]
                                        [--poll-seconds N]
                                        [--model-step Module:Pred4]
                                        [--help]

Environment (fail fast, never logged):

    FORGEJO_URL      base URL of the Forgejo instance
    FORGEJO_TOKEN    access token for the API

Defaults: state_dir(state/run), poll_seconds(30), once. Later flags
override earlier ones. Tests use cli_options/2 and env_options/2
directly; they stay deterministic (no sleeps, no network).
*/

:- use_module(fcopilot(repo_ref)).
:- use_module(fcopilot(service)).
:- use_module(library(lists)).
:- use_module(library(option)).

daemon_defaults([state_dir('state/run'),
                 poll_seconds(30),
                 forever(false)]).

%% cli_options(+Argv, -Options) is semidet.
% Parsed flags first (so they shadow the defaults for option/3 lookups),
% defaults last. --repo accumulates; the last --once/--forever wins.
cli_options(Argv, Options) :-
    parse_argv(Argv, [], Parsed),
    daemon_defaults(Defaults),
    append(Parsed, Defaults, Options).

%% parse_argv(+Argv, +Acc, -Options) is det.
parse_argv([], Acc, Acc).
parse_argv([Flag | Rest], Acc, Options) :-
    flag_option(Flag, Rest, Option, Rest1),
    !,
    merge_option(Option, Acc, Acc1),
    parse_argv(Rest1, Acc1, Options).
parse_argv([Unknown | _], _Acc, _) :-
    format(user_error, 'copilot-service: unknown argument ~w~n', [Unknown]),
    fail.

flag_option('--once', Rest, forever(false), Rest).
flag_option('--forever', Rest, forever(true), Rest).
flag_option('--help', Rest, help, Rest).
flag_option('--state-dir', [Value | Rest], state_dir(Dir), Rest) :-
    atom_string(Dir, Value).
flag_option('--poll-seconds', [Value | Rest], poll_seconds(N), Rest) :-
    atom_number(Value, N),
    N > 0.
flag_option('--model-step', [Value | Rest], model_step(Callable), Rest) :-
    term_string(Callable, Value).
flag_option('--repo', [Value | Rest], repos([Repo]), Rest) :-
    split_repo(Value, _Owner, _Name),
    atom_string(Repo, Value).

% --repo accumulates; every other parsed option replaces an earlier one.
merge_option(repos([Repo]), Acc, [repos(Repos) | Rest]) :-
    (   select(repos(Repos0), Acc, Rest)
    ->  append(Repos0, [Repo], Repos)
    ;   Rest = Acc,
        Repos = [Repo]
    ).
merge_option(help, Acc, [help | Acc]).
merge_option(Option, Acc, [Option | Rest]) :-
    functor(Option, Name, _),
    (   select_name(Name, Acc, Rest)
    ->  true
    ;   Rest = Acc
    ).

select_name(Name, [Option | Rest], Out) :-
    (   functor(Option, Name, _)
    ->  Out = Rest
    ;   Out = [Option | Rest0],
        select_name(Name, Rest, Rest0)
    ).

%% env_options(+CliOptions, -Options) is semidet.
% Fail fast: credentials must be present and non-empty, and at least one
% repository must be selected. Failures here are configuration errors,
% not transient conditions — the daemon exits nonzero with a message.
env_options(Options, Options) :-
    required_env('FORGEJO_URL'),
    required_env('FORGEJO_TOKEN'),
    memberchk(repos(Repos), Options),
    Repos \== [],
    !.

required_env(Name) :-
    getenv(Name, Value),
    Value \== '',
    !.
required_env(Name) :-
    format(user_error, 'copilot-service: environment variable ~w must be set and non-empty~n', [Name]),
    fail.

%% run(+Options) is det.
% Resume paused (crashed) runs first — a fresh process must pick up the
% durable checkpoints — then poll once or forever.
run(Options) :-
    catch(service:resume_paused(Options), Error,
          print_message(error, daemon(resume_failed(Error)))),
    (   option(forever(true), Options)
    ->  loop(Options)
    ;   catch(service:poll_once(Options), Error0,
              print_message(error, daemon(poll_failed(Error0))))
    ).

loop(Options) :-
    catch(service:poll_once(Options), Error,
          print_message(error, daemon(poll_failed(Error)))),
    option(poll_seconds(Seconds), Options),
    sleep(Seconds),
    loop(Options).

%% daemon_main(+Argv) is det.
% Process entry point: parse, validate, run, exit. Used by
% bin/copilot-service.pl; tests use the pieces instead.
daemon_main(Argv) :-
    (   cli_options(Argv, CliOptions)
    ->  (   memberchk(help, CliOptions)
        ->  print_usage,
            halt(0)
        ;   env_options(CliOptions, Options)
        ->  run(Options),
            halt(0)
        ;   halt(1)                      % env_options printed the reason
        )
    ;   print_usage,
        halt(2)
    ).

print_usage :-
    format('usage: copilot-service [--once|--forever] --repo Owner/Name~n'),
    format('                      [--state-dir Dir] [--poll-seconds N]~n'),
    format('                      [--model-step Module:Pred4]~n'),
    format('env:   FORGEJO_URL, FORGEJO_TOKEN (required, never logged)~n').
