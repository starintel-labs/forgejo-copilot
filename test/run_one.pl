/* Focused development runner: run one test file's suites.
   Usage: swipl -q -s test/run_one.pl -- 02_config.pl */
:- set_prolog_flag(on_error, status).
:- initialization(main, main).

:- use_module(library(plunit)).
:- use_module('loader.pl').

:- prolog_load_context(source, RunnerFile),
   file_directory_name(RunnerFile, RunnerDir),
   assertz(fcopilot_loader:runner_dir(RunnerDir)),
   true.

main(Argv0) :-
    strip_separator(Argv0, Argv),
    (   catch(argv_options(Argv, Rest, _Options), E,
              (   print_message(error, E),
                  halt(2)
              ))
    ->  true
    ;   halt(2)
    ),
    (   Rest = [File]
    ->  true
    ;   format(user_error, 'usage: run_one.pl -- <test-file-name>~n', []),
        halt(2)
    ),
    fcopilot_loader:setup_paths,
    set_test_options([]),
    fcopilot_loader:runner_dir(Dir),
    format(atom(Path), '~w/~w', [Dir, File]),
    (   catch(load_files(Path, []), LoadError,
              (   print_message(error, LoadError),
                  halt(1)
              ))
    ->  true
    ;   halt(1)
    ),
    (   catch(run_tests(all, [summary(Summary), timeout(20), cleanup(false)]),
              RunError,
              (   print_message(error, RunError),
                  fail
              ))
    ->  (   fcopilot_loader:summary_ok(Summary)
        ->  halt(0)
        ;   halt(1)
        )
    ;   format(user_error, 'run_one: test run failed~n', []),
        halt(1)
    ).

strip_separator(['--' | Rest], Rest) :- !.
strip_separator(Argv, Argv).