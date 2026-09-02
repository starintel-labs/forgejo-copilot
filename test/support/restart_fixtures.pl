:- module(restart_fixtures,
          [ tmp_state_dir/1,
            counter_file/2,
            worker/3,
            journal_open_at/1
          ]).

/** <module> Restart fixture helpers */

:- use_module(library(process)).

tmp_state_dir(Dir) :-
    current_prolog_flag(pid, Pid),
    (   getenv('TMPDIR', T0), T0 \== ''
    ->  T = T0
    ;   T = '/tmp'
    ),
    format(atom(Dir), '~w/fcopilot-restart-~w', [T, Pid]),
    catch(delete_directory_and_contents(Dir), _, true),
    make_directory_path(Dir).

counter_file(Dir, Path) :-
    format(atom(Path), '~w/counter', [Dir]).

%% worker(+Phase, +StateDir, -ExitedCleanly) is det.
% Runs one worker phase. ExitedCleanly is `clean` when the worker exited 0
% on its own, `killed` when it was killed after the timeout (halt can wait
% on lingering async workers — prolog-rlm's own restart fixtures use the
% same wait-with-timeout-and-kill pattern), or the process status.
worker(Phase, StateDir, ExitedCleanly) :-
    current_prolog_flag(executable, Swipl),
    source_file(restart_fixtures:tmp_state_dir(_), ThisFile),
    file_directory_name(ThisFile, SupportDir),
    file_directory_name(SupportDir, TestDir),
    format(atom(Script), '~w/scripts/service_worker.pl', [TestDir]),
    catch(process_create(Swipl,
                         ['-q', '-s', file(Script), '--', Phase, StateDir],
                         [process(Pid)]),
          Error,
          (   format(user_error, 'worker spawn failed: ~w~n', [Error]),
              fail
          )),
    catch(process_wait(Pid, Status, [timeout(20)]),
          _,
          Status = timeout),
    (   Status == timeout
    ->  catch(process_kill(Pid, kill), _, true),
        catch(process_wait(Pid, _), _, true),
        ExitedCleanly = killed
    ;   Status == exit(0)
    ->  ExitedCleanly = clean
    ;   ExitedCleanly = Status
    ).

journal_open_at(Dir) :-
    format(atom(Path), '~w/journal.pl', [Dir]),
    (   exists_file(Path)
    ->  use_module(fcopilot(journal)),
        journal:open(Path)
    ;   format(user_error, 'fixture: journal missing at ~w~n', [Path]),
        fail
    ).
