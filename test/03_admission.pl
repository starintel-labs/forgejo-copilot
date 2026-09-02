/* Admission gate — runtime realization of the spec gate.
   Ported invariants: base-HEAD-only .copilot (the caller supplies the
   config read from the base HEAD), opt-out, non-bot triggers,
   posted-effect idempotency keyed on (repo, pr, sha), force-push
   re-admit, one lease per (repo, pr) with fencing, journal-backed
   lease and effect records. */

:- use_module(fcopilot_spec(forgejo_copilot_spec)).
:- use_module(fcopilot(copilot_config)).
:- use_module(fcopilot(admission)).
:- use_module(fcopilot(forgejo_event)).
:- use_module(fcopilot(journal)).

cfg(config{enabled:true, model:fast, auto:true, tasks:true}).
mention(E) :-
    E = event{actor:alice, actor_kind:human, kind:mention,
              body:'@copilot fix the flaky test'}.

:- begin_tests(admission_gate).

test(disabled_config_never_admits) :-
    cfg(C0),
    C = C0.put(enabled, false),
    mention(E),
    \+ admission:admit('o/r', 7, sha1, E, C, [], _).

test(mention_admits_task_route) :-
    cfg(C), mention(E),
    admission:admit('o/r', 7, sha1, E, C, [], ok(Grant)),
    Grant.route == task,
    Grant.config == C.

test(command_review_routes_review) :-
    cfg(C),
    E = event{actor:bob, actor_kind:human, kind:command, command:'/review'},
    admission:admit('o/r', 7, sha1, E, C, [], ok(Grant)),
    Grant.route == review.

test(command_ask_routes_task) :-
    cfg(C),
    E = event{actor:bob, actor_kind:human, kind:command, command:'/ask'},
    admission:admit('o/r', 7, sha1, E, C, [], ok(Grant)),
    Grant.route == task.

test(auto_review_pr_opened_routes_review) :-
    cfg(C),
    E = event{actor:bob, actor_kind:human, kind:pr_opened},
    admission:admit('o/r', 7, sha1, E, C, [], ok(Grant)),
    Grant.route == review.

test(posted_effect_same_sha_blocked) :-
    cfg(C), mention(E),
    \+ admission:admit('o/r', 7, sha1, E, C,
                       [posted_effect('o/r', 7, sha1)], _).

test(force_push_new_sha_readmits) :-
    cfg(C), mention(E),
    admission:admit('o/r', 7, sha2, E, C,
                    [posted_effect('o/r', 7, sha1)], ok(_)).

test(bot_events_never_admit) :-
    cfg(C),
    E = event{actor:copilot, actor_kind:bot, kind:command, command:'/review'},
    \+ admission:admit('o/r', 7, sha1, E, C, [], _).

test(active_lease_blocks_second_task) :-
    cfg(C), mention(E),
    \+ admission:admit('o/r', 7, sha1, E, C, [lease('o/r', 7, held)], _).

test(lease_fencing_single_token_per_repo_pr) :-
    cfg(C), mention(E),
    admission:admit('o/r', 7, sha1, E, C, [], ok(_)),
    \+ admission:admit('o/r', 7, sha1, E, C, [lease('o/r', 7, tok)], ok(_)).

:- end_tests(admission_gate).

:- begin_tests(forgejo_event_translation).

test(mention_body_detection) :-
    forgejo_event:event_kind("alice", false,
                             "@copilot please fix the flaky test", mention),
    forgejo_event:event_command("@copilot please fix the flaky test", none).

test(command_review) :-
    forgejo_event:event_kind("bob", false, "/review", command),
    forgejo_event:event_command("/review", '/review').

test(command_ask) :-
    forgejo_event:event_kind("bob", false, "/ask what does this do", command),
    forgejo_event:event_command("/ask what does this do", '/ask').

test(bot_actor_flagged) :-
    forgejo_event:is_bot_actor("forgejo-copilot", true),
    forgejo_event:is_bot_actor("someone[bot]", true).

test(human_mention_case_insensitive_prefix) :-
    forgejo_event:event_kind("alice", false, "@Copilot do the thing", mention).

test(random_text_is_ignored) :-
    \+ forgejo_event:event_kind("alice", false,
                                "hey can someone copilot this", _Kind).

test(non_bot_actor_flag_guard) :-
    % when the API flag says not-bot, the name heuristic still catches bots
    forgejo_event:is_bot_actor("copilot-helper", false),
    \+ forgejo_event:is_bot_actor("unseen", false).

:- end_tests(forgejo_event_translation).

:- begin_tests(journal_lease_and_effects).

test(journal_lease_release_and_fence) :-
    journal:with_test_journal(
        (   journal:lease_acquire('o/r', 7, shaA, Tok1),
            journal:lease_held('o/r', 7, Tok1),
            \+ journal:lease_held('o/r', 7, other),
            journal:lease_runs(run('o/r', 7, shaA)),
            journal:lease_release('o/r', 7, Tok1),
            journal:lease_acquire('o/r', 7, shaB, Tok2),
            Tok2 \= Tok1
        )).

test(journal_lease_survives_reopen) :-
    journal:tmp_journal(Path),
    setup_call_cleanup(
        journal:open(Path),
        (   journal:lease_acquire('o/r', 7, shaX, Tok),
            journal:lease_held('o/r', 7, Tok),
            journal:close,
            journal:open(Path),
            journal:lease_held('o/r', 7, Tok)
        ),
        (   catch(journal:close, _, true),
            catch(delete_file(Path), _, true)
        )).

test(journal_posted_effect_blocks_same_sha) :-
    journal:with_test_journal(
        (   journal:record_effect('o/r', 7, sha1, comment, ev1),
            journal:effect_posted('o/r', 7, sha1),
            \+ journal:effect_posted('o/r', 7, sha2)
        )).

test(journal_seen_events_idempotent) :-
    journal:with_test_journal(
        (   \+ journal:seen('o/r:7:sha1:mention:1'),
            journal:mark_seen('o/r:7:sha1:mention:1'),
            journal:seen('o/r:7:sha1:mention:1')
        )).

:- end_tests(journal_lease_and_effects).
