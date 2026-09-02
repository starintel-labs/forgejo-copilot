:- set_prolog_flag(on_error, status).
:- initialization(main, main).

:- use_module(library(plunit)).
:- use_module('loader.pl').

% Test files follow the numeric-prefix convention (NN_name.pl). Every
% present file is loaded; the gate fails closed while any file fails to
% load or any test fails. Focused development runs use test/run_one.pl.

:- prolog_load_context(source, RunnerFile),
   file_directory_name(RunnerFile, RunnerDir),
   assertz(fcopilot_loader:runner_dir(RunnerDir)),
   true.

test_files(Files) :-
    fcopilot_loader:runner_dir(Dir),
    format(atom(Pattern), '~w/??_*.pl', [Dir]),
    expand_file_name(Pattern, All),
    maplist(basename, All, Files).

basename(Path, Base) :-
    file_base_name(Path, Base0),
    file_name_extension(Base, _Ext, Base0).

main(_) :-
    fcopilot_loader:setup_paths,
    set_test_options([]),
    test_files(Files),
    forall(member(File, Files),
           (   fcopilot_loader:runner_dir(Dir),
               format(atom(Path), '~w/~w', [Dir, File]),
               (   catch(load_files(Path, []), LoadError,
                       (   print_message(error, LoadError),
                           fail
                       ))
               ->  true
               ;   format(user_error, 'RUNNER: failed to load ~w~n', [Path]),
                   halt(1)
               )
           )),
    (   catch(run_tests(all, [summary(Summary), timeout(20), cleanup(false)]),
              Error,
              (   print_message(error, Error),
                  fail
              ))
    ->  (   fcopilot_loader:summary_ok(Summary)
        ->  halt(0)
        ;   halt(1)
        )
    ;   format(user_error, 'RUNNER: test execution failed~n', []),
        halt(1)
    ).
