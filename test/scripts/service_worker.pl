/* Fresh-process service worker.
   Usage: swipl -q -s test/scripts/service_worker.pl -- <phase> <state_dir>

   Phases:
     phase1 — process one mention event; the delegate interrupts at
              `planned`; the run pauses with a durable checkpoint.
     phase2 — resume the paused run from the lease's run identity; the run
              completes; side effects are recorded in the counter file.
     phase3 — re-process the SAME event; the posted-effect record must
              refuse it (exactly once); the counter must be unchanged.

   Exits 0 on success, 1 on failure. No sleeps; process hand-off is the
   determinism boundary.
*/

:- prolog_load_context(source, File),
   file_directory_name(File, Dir),
   format(atom(SupportDir), '~w/../support', [Dir]),
   assertz(user:file_search_path(worker_support, SupportDir)),
   true.

:- use_module('../loader.pl').
:- use_module(worker_support(stub_delegate), []).
:- use_module(worker_support(stub_service), []).
:- use_module(worker_support(fake_api), []).
:- use_module(worker_support(stub_interrupt), []).
:- initialization(main, main).

main(Argv) :-
    catch_with_backtrace(
        (   strip(Argv, [Phase, StateDir]),
            fcopilot_loader:setup_paths,
            fcopilot_loader:load_copilot,
            work(Phase, StateDir)
        ),
        E,
        (   E = unwind(_) -> throw(E)
        ;   print_message(error, E),
            (   E = error(_, context(prolog_stack(S), _))
            ->  prolog_stack:print_prolog_backtrace(user_error, S)
            ;   format('no stack~n', [])
            ),
            halt(2)
        )).

work(phase1, StateDir) :-
    !,
    process_event_once(StateDir, stub_interrupt),
    (   journal:lease_runs(run('o/r', 7, _Sha))
    ->  halt(0)
    ;   format(user_error, 'phase1: no paused lease~n', []),
        halt(1)
    ).
work(phase2, StateDir) :-
    !,
    Options = [state_dir(StateDir), delegate(stub_service),
               api(fake_api:api)],
    service:resume_paused(Options),
    fake_api:count(N),
    (   N >= 1
    ->  halt(0)
    ;   format(user_error, 'phase2: no side effects recorded~n', []),
        halt(1)
    ).
work(phase3, StateDir) :-
    !,
    fake_api:count(Before),
    process_event_once(StateDir, stub_service),
    fake_api:count(After),
    (   Before == After
    ->  format('phase3: exactly-once verified (~w side effects)~n', [After]),
        halt(0)
    ;   format(user_error,
               'phase3: DUPLICATE side effect (~w -> ~w)~n', [Before, After]),
        halt(1)
    ).

process_event_once(StateDir, DelegateModule) :-
    Options = [state_dir(StateDir),
               delegate(DelegateModule),
               api(fake_api:api)],
    Polled = polled{repo:'o/r', pr:7, sha:sha1,
                    login:'alice', bot:false,
                    body:'@copilot fix the parser bug',
                    kind_hint:comment, event_id:evt1},
    Event = event{actor:alice, actor_kind:human, kind:mention,
                  body:'@copilot fix the parser bug'},
    service:process_event('o/r', Polled, Event, 'o/r:7:sha1:evt1', Options).

strip(['--' | Rest], Rest) :- !.
strip(X, X).
