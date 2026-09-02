/* Fresh-process restart fixture (acceptance criterion 2).

   Three separate swipl processes drive one event through the pipeline:

     proc A: process event -> graph pauses at planned (durable checkpoint)
     proc B: resume from the lease's run identity -> completes; the fake
             API records side effects in a counter FILE (external state,
             independent of the journal)
     proc C: re-process the same event -> refused(already_done); the
             counter file must be unchanged (exactly once)

   Determinism: process hand-off is the only synchronization. Workers are
   awaited with a timeout and killed on overrun (prolog-rlm's own restart
   fixtures use the same pattern — halt can wait on lingering async
   workers), so success is verified through externally observable state
   (the counter file and the journal), never through exit codes.

   KNOWN ISSUE (hand-off): phase 2 currently exits with a silent failure
   or hangs before resume_one's checkpoint read; see HANDOFF.md for the
   repro, evidence, and next steps. The assertions below describe the
   INTENDED contract and are the acceptance gate for the fix.
*/

:- use_module('loader.pl').
:- use_module('support/fake_api.pl').
:- use_module('support/restart_fixtures.pl').
:- use_module(library(process)).

:- begin_tests(restart_pipeline).

test(pause_resume_repoll_across_processes, [timeout(120)]) :-
    restart_fixtures:tmp_state_dir(Dir),
    restart_fixtures:counter_file(Dir, Counter),
    setenv('COPILOT_TEST_COUNTER', Counter),
    touch(Counter),

    % Phase 1: admit + pause at planned, durable checkpoint, lease held.
    restart_fixtures:worker(phase1, Dir, W1),
    member(W1, [clean, killed]),
    restart_fixtures:journal_open_at(Dir),
    journal:lease_runs(run('o/r', 7, sha1)),
    fake_api:count(0),                       % nothing posted while paused
    journal:close,

    % Phase 2: fresh process resumes from the lease's run identity.
    restart_fixtures:worker(phase2, Dir, _W2),
    fake_api:count(N1),
    N1 >= 4,                                 % branch+push+pr+reply recorded

    % Phase 3: re-poll the same event -> exactly-once.
    restart_fixtures:worker(phase3, Dir, _W3),
    fake_api:count(N2),
    N2 == N1,

    catch(delete_directory_and_contents(Dir), _, true).

touch(File) :-
    (   exists_file(File)
    ->  true
    ;   open(File, write, S),
        close(S)
    ).

:- end_tests(restart_pipeline).
