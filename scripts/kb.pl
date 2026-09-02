#!/usr/bin/env swipl
/* forgejo-copilot build-task knowledge base.

   Multi-session coordination: any session (human or agent) tracks build
   task state here. Facts live in state/tasks.pl; every mutation
   rewrites the file atomically while holding an exclusive-claim lock
   file, so concurrent sessions cannot interleave writes.

   Usage:
     swipl -s scripts/kb.pl -g "kb_status,halt"                        -- list
     swipl -s scripts/kb.pl -g "kb_add_task(t_tests,'tests'),halt"     -- add
     swipl -s scripts/kb.pl -g "kb_set_task(t_tests,in_progress,'why'),halt"
     swipl -s scripts/kb.pl -g "kb_add_dep(t_impl,t_spec),halt"
     swipl -s scripts/kb.pl -g "kb_add_evidence(t_spec,'30/30','session X'),halt"
     swipl -s scripts/kb.pl -g "kb_log('what happened'),halt"

   Status vocabulary: pending | in_progress | done | blocked | cancelled.
   Evidence entries must cite the exact thing that was run (session id,
   command, test name). Never record a verification that did not run.

   Set KB_SESSION=<name> in the environment to identify the session.
*/

:- use_module(library(lists)).

:- dynamic kb_task/4.
:- dynamic kb_dep/2.
:- dynamic kb_event/3.
:- dynamic kb_evidence/3.

kb_file('state/tasks.pl').
kb_lock('state/.kb.lock').

valid_status(pending).
valid_status(in_progress).
valid_status(done).
valid_status(blocked).
valid_status(cancelled).

%% -- lock -------------------------------------------------------------------
% Atomic claim: open with create([exclusive]) fails if the lock exists.
% The stream (and thus the claim) stays open for the whole critical section.

with_lock(Goal) :-
    kb_lock(Lock),
    file_directory_name(Lock, Dir),
    make_directory_path(Dir),
    lock_claim(Lock, 200, S),
    call_cleanup(call(Goal),
                 (   close(S),
                     catch(delete_file(Lock), _, true)
                 )).

lock_claim(Lock, _, S) :-
    catch(open(Lock, write, S, [create([exclusive])]), _, fail),
    !.
lock_claim(Lock, 0, S) :- !,
    format(user_error, 'kb: breaking stale lock~n', []),
    catch(delete_file(Lock), _, true),
    catch(open(Lock, write, S, [create([exclusive])]), _, fail).
lock_claim(Lock, N, S) :-
    (   N mod 40 =:= 0,
        exists_file(Lock),
        time_file(Lock, T0),
        get_time(Now),
        Now - T0 > 60
    ->  catch(delete_file(Lock), _, true)   % stale lock from dead session
    ;   true
    ),
    N2 is N - 1,
    sleep(0.05),
    lock_claim(Lock, N2, S).

%% -- load / save ----------------------------------------------------------
kb_load :-
    kb_file(File),
    (   exists_file(File)
    ->  kb_reset_dynamic,
        setup_call_cleanup(
            open(File, read, S),
            (   repeat,
                catch(read_term(S, Term, []),
                      Error,
                      (   print_message(warning, Error),
                          Term = end_of_file
                      )),
                (   Term == end_of_file
                ->  !
                ;   assert_kb_term(Term),
                    fail
                )
            ),
            close(S))
    ;   true
    ).

kb_reset_dynamic :-
    forall((kb_fact(F, A),
            current_predicate(F/A)),
           catch(abolish(F/A), _, true)),
    forall(kb_fact(F, A), dynamic(F/A)).

assert_kb_term(Term) :-
    (   kb_fact(Functor, Arity),
        functor(Term, Functor, Arity)
    ->  assertz(Term)
    ;   format(user_error, 'kb: ignoring unknown fact ~w~n', [Term])
    ).

kb_fact(kb_task, 4).
kb_fact(kb_dep, 2).
kb_fact(kb_event, 3).
kb_fact(kb_evidence, 3).

kb_save :-
    kb_file(File),
    file_directory_name(File, Dir),
    make_directory_path(Dir),
    current_prolog_flag(pid, Pid),
    format(atom(Tmp), '~w.tmp.~w', [File, Pid]),
    setup_call_cleanup(
        open(Tmp, write, S),
        (   forall(kb_task(Id, Status, Session, Note),
                   format(S, 'kb_task(~q, ~q, ~q, ~q).~n',
                          [Id, Status, Session, Note])),
            forall(kb_dep(Task, Dep),
                   format(S, 'kb_dep(~q, ~q).~n', [Task, Dep])),
            forall(kb_event(Ts, Session, What),
                   format(S, 'kb_event(~q, ~q, ~q).~n', [Ts, Session, What])),
            forall(kb_evidence(Task, Evidence, Provenance),
                   format(S, 'kb_evidence(~q, ~q, ~q).~n',
                          [Task, Evidence, Provenance]))
        ),
        close(S)),
    rename_file(Tmp, File).

now_ts(T) :-
    get_time(T).

session_id(S) :-
    (   getenv('KB_SESSION', S0)
    ->  S = S0
    ;   current_prolog_flag(pid, P),
        format(atom(S), 'session-~w', [P])
    ).

%% -- operations -----------------------------------------------------------
kb_add_task(Id, Title) :-
    kb_add_task(Id, Title, pending).

kb_add_task(Id, Title, Status) :-
    valid_status(Status),
    with_lock((
        kb_load,
        (   kb_task(Id, _, _, _)
        ->  format('kb: task ~w already exists~n', [Id])
        ;   session_id(S),
            assertz(kb_task(Id, Status, S, Title)),
            kb_save,
            format('kb: added ~w (~w)~n', [Id, Status])
        ))).

kb_set_task(Id, Status, Note) :-
    valid_status(Status),
    with_lock((
        kb_load,
        (   kb_task(Id, _, _, _)
        ->  retractall(kb_task(Id, _, _, _)),
            session_id(S),
            assertz(kb_task(Id, Status, S, Note)),
            kb_save,
            format('kb: ~w -> ~w~n', [Id, Status])
        ;   format('kb: unknown task ~w~n', [Id]),
            fail
        ))).

kb_add_dep(Task, Dep) :-
    with_lock((
        kb_load,
        (   kb_dep(Task, Dep)
        ->  format('kb: dep ~w -> ~w already recorded~n', [Task, Dep])
        ;   assertz(kb_dep(Task, Dep)),
            kb_save,
            format('kb: ~w depends on ~w~n', [Task, Dep])
        ))).

kb_add_evidence(Task, Evidence, Provenance) :-
    with_lock((
        kb_load,
        (   kb_evidence(Task, Evidence, Provenance)
        ->  format('kb: evidence already recorded~n', [])
        ;   assertz(kb_evidence(Task, Evidence, Provenance)),
            kb_save,
            format('kb: evidence for ~w recorded~n', [Task])
        ))).

kb_log(What) :-
    with_lock((
        kb_load,
        now_ts(T),
        session_id(S),
        assertz(kb_event(T, S, What)),
        kb_save,
        format('kb: logged~n', [])
    )).

%% -- queries --------------------------------------------------------------
kb_status :-
    kb_load,
    (   kb_task(Id, Status, Session, Note)
    ->  format('~w  [~w]  (~w)  ~w~n', [Id, Status, Session, Note])
    ;   format('kb: no tasks~n', [])
    ),
    forall(kb_dep(Task, Dep), format('  dep: ~w requires ~w~n', [Task, Dep])),
    forall(kb_evidence(Task, E, P),
           format('  evidence: ~w | ~w | ~w~n', [Task, E, P])),
    forall(kb_event(T, S, W), format('  event: ~w ~w ~w~n', [T, S, W])).

kb_ready_tasks(Ready) :-
    kb_load,
    findall(Id,
            (   kb_task(Id, pending, _, _),
                \+ (   kb_dep(Id, Dep),
                       kb_task(Dep, DepStatus, _, _),
                       DepStatus \== done
                   )
            ),
            Ready).
