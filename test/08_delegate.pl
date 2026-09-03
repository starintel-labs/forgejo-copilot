/* Real delegate — unit tests with a fake Forgejo api hook and a fake
   model step. Deterministic: no network, no sleeps; the journal is a
   temp store per test. Covers: structured plan parsing (fences, cap,
   empty, unexpected fields, unsafe paths), reusable fence stripping,
   real file content fetch + model rewrite + base64 push, run_id spend
   threading, review citation filtering, request-changes-only reviews
   (never approve), empty-review skip, effect idempotency, and reply
   citations.

   Fixture notes: every goal handed to journal:with_test_journal/1 is
   module-qualified (user:) — the body predicates below live at file
   level, and an unqualified goal would otherwise resolve in module
   `journal`, where none of them exist. The fake hooks are likewise
   handed to the delegate as user:-qualified closures because the
   delegate module can only see them through the user context. */

:- use_module('loader.pl').
:- use_module(fcopilot_spec(forgejo_copilot_spec)).
:- use_module(fcopilot(copilot_delegate)).
:- use_module(fcopilot(journal)).
:- use_module(fcopilot(llm_text)).
:- use_module(library(base64)).
:- use_module(library(lists)).

:- begin_tests(llm_text).

test(strip_fenced_with_language_tag) :-
    llm_text:strip_code_fences("```json\n[{\"a\":1}]\n```", Out),
    Out == "[{\"a\":1}]".

test(strip_fenced_plain_preserves_inner_newlines) :-
    llm_text:strip_code_fences("```\nline1\nline2\n\n```", Out),
    Out == "line1\nline2\n".

test(strip_tolerates_trailing_blank_lines) :-
    llm_text:strip_code_fences("```\ncode\n```\n\n  \n", Out),
    Out == "code".

test(unfenced_text_unchanged) :-
    llm_text:strip_code_fences("just plain text", Out),
    Out == "just plain text".

test(empty_fence_yields_empty) :-
    llm_text:strip_code_fences("```\n\n```", Out),
    Out == "".

:- end_tests(llm_text).

:- begin_tests(delegate_plan).

test(plan_parses_fenced_json) :-
    plan_json_text(["[{\"path\":\"src/a.pl\",",
                    "\"change\":\"fix loop\",",
                    "\"message\":\"fix the loop bug\"}]"], Text),
    grant_state(Text, State),
    copilot_delegate:node(planned, State, ctx, ok(Patch)),
    get_dict(data, Patch, Data),
    get_dict(plan, Data, [Plan0]),
    get_dict(path, Plan0, 'src/a.pl'),
    get_dict(change, Plan0, 'fix loop'),
    get_dict(message, Plan0, 'fix the loop bug').

test(plan_rejects_invalid_json) :-
    grant_state("this is not json", State),
    \+ copilot_delegate:node(planned, State, ctx, _Outcome).

test(plan_rejects_empty) :-
    grant_state("[]", State),
    \+ copilot_delegate:node(planned, State, ctx, _Outcome).

test(plan_rejects_over_cap) :-
    findall(Item,
            (   between(1, 17, N),
                format(atom(Item),
                       '{"path":"src/~w.pl","change":"c","message":"m"}', [N])
            ),
            Items),
    atomic_list_concat(Items, ",", Joined),
    format(atom(Text), "[~w]", [Joined]),
    grant_state(Text, State),
    \+ copilot_delegate:node(planned, State, ctx, _Outcome).

test(plan_rejects_unexpected_fields) :-
    plan_json_text(["[{\"path\":\"src/a.pl\",\"change\":\"c\",",
                    "\"message\":\"m\",\"shell\":\"rm -rf\"}]"], Text),
    grant_state(Text, State),
    \+ copilot_delegate:node(planned, State, ctx, _Outcome).

test(plan_rejects_unsafe_path) :-
    plan_json_text(["[{\"path\":\"../etc/passwd\",\"change\":\"c\",",
                    "\"message\":\"m\"}]"], Text),
    grant_state(Text, State),
    \+ copilot_delegate:node(planned, State, ctx, _Outcome).

:- end_tests(delegate_plan).

:- begin_tests(delegate_implement).

test(implemented_fetches_and_pushes_content) :-
    journal:with_test_journal(user:impl_body).

test(implemented_rejects_empty_model_content) :-
    journal:with_test_journal(user:impl_empty_body).

:- end_tests(delegate_implement).

:- begin_tests(delegate_review).

test(review_filters_uncited_findings) :-
    ModelText = "good line src/a.pl:12\nunsupported claim without file\n",
    review_state(ModelText, State),
    copilot_delegate:node(reviewed, State, ctx, ok(Patch)),
    get_dict(data, Patch, Data),
    get_dict(findings, Data, Findings),
    Findings == ["good line src/a.pl:12"].

test(posted_uses_request_changes_only) :-
    journal:with_test_journal(user:review_post_body).

test(posted_skips_when_no_findings) :-
    journal:with_test_journal(user:review_skip_body).

test(model_step_threads_run_id_for_spend) :-
    journal:with_test_journal(user:spend_body).

:- end_tests(delegate_review).

:- begin_tests(delegate_reply).

test(reply_cites_every_planned_path) :-
    journal:with_test_journal(user:reply_body).

:- end_tests(delegate_reply).

% -- test bodies (file level: with_test_journal goals resolve here) ----------

impl_body :-
    Content = "line1\nline2\n",
    atomic_list_concat(["```", Content, "```"], "\n", ModelText),
    impl_state(ModelText, State),
    copilot_delegate:node(branched, State, ctx, _),
    copilot_delegate:node(implemented, State, ctx, ok(Patch)),
    get_dict(data, Patch, Data),
    get_dict(commits, Data, [Commit]),
    get_dict(path, Commit, 'src/a.pl'),
    last_push(Push),
    get_dict(content_b64, Push, B64),
    atom_codes(B64, B64Codes),
    phrase(base64(PlainCodes), B64Codes),
    atom_codes(Content, PlainCodes),
    get_dict(branch, Push, Branch),
    atom_concat('copilot/', _, Branch).

impl_empty_body :-
    impl_state("```\n\n```", State),
    copilot_delegate:node(branched, State, ctx, _),
    \+ copilot_delegate:node(implemented, State, ctx, ok(_)).

review_post_body :-
    review_state("finding src/a.pl:1\n", State),
    copilot_delegate:node(reviewed, State, ctx, ok(P1)),
    apply_patch(State, P1, State1),
    copilot_delegate:node(deduped, State1, ctx, ok(P2)),
    apply_patch(State1, P2, State2),
    copilot_delegate:node(posted, State2, ctx, ok(_)),
    last_review(Review),
    get_dict(event, Review, request_changes).

review_skip_body :-
    review_state("nothing actionable here\n", State),
    copilot_delegate:node(reviewed, State, ctx, ok(P1)),
    get_dict(data, P1, D1),
    get_dict(findings, D1, []),
    apply_patch(State, P1, State1),
    copilot_delegate:node(deduped, State1, ctx, _),
    review_calls(0).

% The graph engine applies each node's data patch before the next node;
% these bodies replay that behavior directly.
apply_patch(State, Patch, NewState) :-
    get_dict(data, Patch, Data),
    put_dict(data, State, Data, NewState).

% The trusted model step hook is delivered through the run data and the
% delegate threads run:<repo>:<pr>:<sha> so the ledger records spend.
spend_body :-
    review_state("finding src/a.pl:1\n", State),
    copilot_delegate:node(reviewed, State, ctx, ok(_)),
    spend_recorded('run:o/r:7:sha1').

spend_recorded(RunId) :-
    rlm_effect_persist:effect_call_record(_CallId, _Fp, model_call,
        spend_request{run:RunId, role:_Role, provider:_Provider, model:_Model},
        spend-RunId, _Created).

reply_body :-
    reply_state(State),
    copilot_delegate:node(replied, State, ctx, ok(_)),
    last_comment(Comment),
    get_dict(body, Comment, Body),
    sub_string(Body, _, _, _, 'src/a.pl').

% -- fake Forgejo hook (records into dynamic predicates) -----------------------

:- dynamic push_record/1.
:- dynamic review_record/1.
:- dynamic comment_record/1.
:- dynamic review_count/1.

fake_api(get_issue, Args,
         issue{number:N, body:"@copilot fix the parser bug",
               user:login{login:"alice"}}) :-
    (   get_dict(index, Args, N) -> true ; N = 7 ),
    !.
fake_api(get_comment_thread, _, _{comments:[]}) :- !.
fake_api(get_pr, _, _) :- !, fail.
fake_api(get_file_content, _, _{text:"old content\n"}) :- !.
fake_api(create_branch, _, branch{name:'copilot/task-7'}) :- !.
fake_api(push_commit, Args, _{commit_sha:sha(_Path)}) :-
    !,
    retractall(push_record(_)),
    assertz(push_record(Args)).
fake_api(create_pr, _, _{pr_index:42}) :- !.
fake_api(post_issue_comment, Args, _{comment_id:99}) :- !,
    retractall(comment_record(_)),
    assertz(comment_record(Args)).
fake_api(post_pr_review, Args, _{id:5}) :- !,
    retractall(review_record(_)),
    assertz(review_record(Args)),
    (   review_count(N0) -> N1 is N0 + 1 ; N1 = 1 ),
    retractall(review_count(_)),
    assertz(review_count(N1)).
fake_api(get_diff, _, _{diff:"diff --git a/src/a.pl b/src/a.pl\n"}) :- !.
fake_api(list_changed_files, _, _{files:[file{filename:'src/a.pl'}]}) :- !.

last_push(Push) :- push_record(Push).
last_review(Review) :- review_record(Review).
last_comment(Comment) :- comment_record(Comment).
review_calls(N) :- ( review_count(N) -> true ; N = 0 ).

% -- fake model step (data.model_step hook) -------------------------------------

fake_model(Text, _Step, _Request, _Extra, ok(model_response{content:Text})).

% -- state builders --------------------------------------------------------------

grant_state(ModelText, State) :-
    test_grant(Grant),
    State = graph_state{data:run_data{grant:Grant,
                                      api:(user:fake_api),
                                      model_step:(user:fake_model(ModelText))},
                        status:running}.

impl_state(ModelText, State) :-
    test_grant(Grant),
    State0 = graph_state{data:run_data{grant:Grant,
                                       api:(user:fake_api),
                                       model_step:(user:fake_model(ModelText)),
                                       base_branch:'main',
                                       plan:[change{path:'src/a.pl',
                                                    change:'fix the parser',
                                                    message:'fix'}]},
                         status:running},
    copilot_delegate:node(branched, State0, ctx, ok(BPatch)),
    get_dict(data, BPatch, BData),
    put_dict(data, State0, BData, State).

review_state(ModelText, State) :-
    test_grant(Grant),
    State = graph_state{data:run_data{grant:Grant,
                                      api:(user:fake_api),
                                      model_step:(user:fake_model(ModelText)),
                                      diff:"diff --git a/src/a.pl\n",
                                      files:[file{filename:'src/a.pl'}],
                                      comments:[]},
                        status:running}.

reply_state(State) :-
    test_grant(Grant),
    State = graph_state{data:run_data{grant:Grant,
                                      api:(user:fake_api),
                                      plan:[change{path:'src/a.pl',
                                                   change:'fix',
                                                   message:'m'}]},
                        status:running}.

test_grant(grant{repo:'o/r', pr:7, sha:sha1,
                 event:event{actor:alice, actor_kind:human, kind:mention},
                 config:config{enabled:true, model:fast, auto:true,
                               tasks:true},
                 route:task}).

plan_json_text(Lines, Text) :-
    atomic_list_concat(["```json", "\n"], Open),
    atomic_list_concat(Lines, Joined),
    format(atom(Text), "~w~w~w```", [Open, Joined, "\n"]).
