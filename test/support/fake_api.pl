:- module(fake_api,
          [ api/3,
            record/1,
            count/1
          ]).

/** <module> Test API hook

Records side effects as lines in a counter FILE — an externally
observable, ledger-independent record so duplicate execution is
detectable independently of the journal. The counter path comes from
COPILOT_TEST_COUNTER in the environment.
*/

:- use_module(library(lists)).

api(get_issue, Args, issue{number:N,
                           body:"@copilot fix the parser bug",
                           user:login{login:"alice"}}) :-
    (   get_dict(index, Args, N) -> true ; N = 7 ),
    !.
api(get_comment_thread, _, _{comments:[]}) :- !.
api(get_pr, _, _) :- !, fail.
api(get_file_content, _, _{text:"enabled: true\n"}) :- !.
api(create_branch, _, branch{name:created}) :- !,
    record(branch).
api(push_commit, _{path:P}, _{commit_sha:sha(P)}) :- !,
    record(push).
api(create_pr, _, _{pr_index:42}) :- !,
    record(pr).
api(post_issue_comment, _, _{comment_id:99}) :- !,
    record(reply).
api(post_pr_review, _, _{id:5}) :- !,
    record(review).

record(Kind) :-
    counter_file(File),
    setup_call_cleanup(
        open(File, append, S),
        format(S, '~w~n', [Kind]),
        close(S)).

count(Count) :-
    counter_file(File),
    (   exists_file(File)
    ->  setup_call_cleanup(
            open(File, read, S),
            read_lines(S, 0, N),
            close(S)),
        Count = N
    ;   Count = 0
    ).

read_lines(S, N0, N) :-
    (   read_line_to_string(S, Line)
    ->  (   Line == end_of_file
        ->  N = N0
        ;   N1 is N0 + 1,
            read_lines(S, N1, N)
        )
    ;   N = N0
    ).

counter_file(File) :-
    (   getenv('COPILOT_TEST_COUNTER', F)
    ->  File = F
    ;   File = '/tmp/opencode/fcopilot-counter'
    ).
