:- module(journal,
          [ open/1,
            close/0,
            attached/1,
            with_test_journal/1,
            tmp_journal/1,
            open_at/1,

            lease_acquire/4,
            lease_held/3,
            lease_release/3,
            lease_runs/1,
            lease_facts/1,

            effect_record/4,
            record_effect/5,
            effect_posted/4,
            effect_posted/3,
            effect_facts/1,

            mark_seen/1,
            seen/1,

            cursor_get/2,
            cursor_advance/2,

            record_spend/4,

            facts/1
          ]).

/** <module> Durable journal

Thin service-owned wrapper over `prolog-rlm`'s `rlm_effect_persist` — the
sanctioned generic durable boundary. Everything that must survive a restart
lives here:

  * leases          one per (repo, pr) with a fencing token
  * effect records  posted-effect identity keyed on (repo, pr, sha)
  * seen events     per-event-id idempotency for the poll loop
  * cursor          the `updated_since` cursor, one per repo
  * spend records   provider + model per run for spend tracing

The journal is single-writer per store path (enforced by the prolog-rlm
persist backend with an OS advisory lock). A second process fails closed
rather than racing.
*/

:- use_module(library(rlm_effect_persist)).
:- use_module(library(lists)).
:- use_module(library(uuid)).
:- use_module(library(sha)).

%% open(+Path) is semidet.
open(Path) :-
    effect_persist_open(Path).

close :-
    effect_persist_close.

attached(Path) :-
    effect_persist_attached(Path).

%% open_at(+StateDir) is semidet.
% Attach the journal that lives in the given state directory (used by
% fixtures to inspect durable state between fresh-process phases).
open_at(Dir) :-
    format(atom(Path), '~w/journal.pl', [Dir]),
    open(Path).

%% -- test plumbing ----------------------------------------------------------
tmp_journal(Path) :-
    current_prolog_flag(pid, Pid),
    get_time(T),
    (   getenv('TMPDIR', Tmp0)
    ->  true
    ;   Tmp0 = '/tmp'
    ),
    text_to_string(Tmp0, TmpStr),
    (   string_concat(_, "/", TmpStr)
    ->  Base = TmpStr
    ;   string_concat(TmpStr, "/", Base)
    ),
    format(atom(Name), 'fcopilot-test-journal-~w-~w', [Pid, T]),
    format(atom(Path), '~w~w', [Base, Name]),
    catch(delete_file(Path), _, true).

with_test_journal(Goal) :-
    tmp_journal(Path),
    setup_call_cleanup(
        open(Path),
        call(Goal),
        (   close,
            catch(delete_file(Path), _, true)
        )).

%% -- lease: one per (repo, pr) with fencing ---------------------------------
% The lease carries the run identity (head sha) so a fresh process can
% resume the paused graph run after a crash.
lease_acquire(Repo, PR, Sha, Token) :-
    \+ lease_held(Repo, PR, _),
    uuid(Token),
    now(Now),
    key(lease, Repo-PR, CallId),
    Request = lease_request{repo:Repo, pr:PR, sha:Sha, token:Token},
    fingerprint(Request, Fp),
    effect_call(CallId, Fp, lease, Request, lease-Repo-PR, Now, Call),
    effect_persist_put_call(Call),
    ensure_lease_index,
    key(lease_index, idx, IndexId),
    uuid(AddedId),
    Added = lease_event{event_id:AddedId, kind:lease_added,
                        repo:Repo, pr:PR, sha:Sha, token:Token},
    effect_persist_append_event(IndexId, Added),
    !.

lease_held(Repo, PR, Token) :-
    key(lease, Repo-PR, CallId),
    effect_persist_get_call(CallId, _Fp, Call),
    get_dict(request, Call, Request),
    get_dict(token, Request, Token),
    \+ released_event(CallId, Token).

lease_release(Repo, PR, Token) :-
    key(lease, Repo-PR, CallId),
    uuid(EventId),
    Event = lease_event{event_id:EventId, kind:lease_released,
                        token:Token},
    effect_persist_append_event(CallId, Event),
    ensure_lease_index,
    key(lease_index, idx, IndexId),
    uuid(RelId),
    Released = lease_event{event_id:RelId, kind:lease_released_idx,
                           repo:Repo, pr:PR, token:Token},
    effect_persist_append_event(IndexId, Released).

released_event(CallId, Token) :-
    effect_persist_events(CallId, Events),
    member(Event, Events),
    get_dict(kind, Event, lease_released),
    get_dict(token, Event, Token).

ensure_lease_index :-
    \+ (   key(lease_index, idx, CallId),
           effect_persist_get_call(CallId, _Fp, _Call)
       ),
    !,
    now(Now),
    key(lease_index, idx, CallId),
    Request = lease_index_request{},
    fingerprint(Request, Fp),
    effect_call(CallId, Fp, lease_index, Request, lease-index, Now, Call),
    effect_persist_put_call(Call).
ensure_lease_index.

lease_facts(Facts) :-
    findall(lease(Repo, PR, Token),
            lease_held(Repo, PR, Token),
            Facts).

%% lease_runs(-Runs) is nondet.
% Held leases with their run identity, for fresh-process resumption.
% Derived by replaying the append-only lease index so enumeration needs
% no prior knowledge of the keys.
lease_runs(run(Repo, PR, Sha)) :-
    ensure_lease_index,
    key(lease_index, idx, IndexId),
    effect_persist_events(IndexId, Events),
    foldl(lease_index_step, Events, [], Active0),
    reverse(Active0, Active),
    member(active(Repo, PR, Sha, _Token), Active).

lease_index_step(E, ActiveIn, Active) :-
    (   get_dict(kind, E, lease_added)
    ->  Active = [active(E.repo, E.pr, E.sha, E.token) | ActiveIn]
    ;   get_dict(kind, E, lease_released_idx)
    ->  exclude(released_match(E), ActiveIn, Active)
    ;   Active = ActiveIn
    ).

released_match(E, active(Repo, PR, _Sha, Token)) :-
    get_dict(repo, E, Repo),
    get_dict(pr, E, PR),
    get_dict(token, E, Token).

%% -- effect records: posted-effect identity keyed on (repo, pr, sha) --------
record_effect(Repo, PR, Sha, Action, EffectId) :-
    now(Now),
    key(effect, Repo-PR-Sha-Action, CallId),
    Request = effect_request{repo:Repo, pr:PR, sha:Sha, action:Action,
                             effect_id:EffectId},
    fingerprint(Request, Fp),
    effect_call(CallId, Fp, posted_effect, Request,
                effect-Repo-PR-Sha-Action, Now, Call),
    effect_persist_put_call(Call).

effect_record(Repo, PR, Sha, Call) :-
    member(Action, [comment, review, pr, branch, push]),
    key(effect, Repo-PR-Sha-Action, CallId),
    effect_persist_get_call(CallId, _Fp, Call).

effect_posted(Repo, PR, Sha, Call) :-
    effect_record(Repo, PR, Sha, Call).

effect_posted(Repo, PR, Sha) :-
    effect_posted(Repo, PR, Sha, _Call).

effect_facts(Facts) :-
    findall(posted_effect(Repo, PR, Sha),
            effect_posted(Repo, PR, Sha),
            Facts).

%% -- seen events ------------------------------------------------------------
mark_seen(EventKey) :-
    now(Now),
    key(seen, EventKey, CallId),
    Request = seen_request{event:EventKey},
    fingerprint(Request, Fp),
    effect_call(CallId, Fp, seen_event, Request, seen-EventKey, Now, Call),
    effect_persist_put_call(Call).

seen(EventKey) :-
    key(seen, EventKey, CallId),
    effect_persist_get_call(CallId, _Fp, _Call).

%% -- cursor -----------------------------------------------------------------
cursor_get(Repo, Cursor) :-
    key(cursor, Repo, CallId),
    effect_persist_events(CallId, Events),
    last(Events, Last),
    get_dict(cursor, Last, Cursor).

cursor_advance(Repo, Cursor) :-
    (   cursor_get(Repo, _Old)
    ->  true
    ;   ensure_cursor_call(Repo)
    ),
    key(cursor, Repo, CallId),
    uuid(EventId),
    Event = cursor_event{event_id:EventId, cursor:Cursor},
    effect_persist_append_event(CallId, Event).

ensure_cursor_call(Repo) :-
    \+ (   key(cursor, Repo, CallId),
           effect_persist_get_call(CallId, _Fp, _Call)
       ),
    !,
    now(Now),
    key(cursor, Repo, CallId),
    Request = cursor_request{repo:Repo},
    fingerprint(Request, Fp),
    effect_call(CallId, Fp, cursor, Request, cursor-Repo, Now, Call),
    effect_persist_put_call(Call).
ensure_cursor_call(_Repo).

%% -- spend tracing ------------------------------------------------------------
record_spend(RunId, Role, Provider, Model) :-
    now(Now),
    uuid(U),
    format(atom(CallId), 'spend:~w:~w', [RunId, U]),
    Request = spend_request{run:RunId, role:Role,
                            provider:Provider, model:Model},
    fingerprint(Request, Fp),
    effect_call(CallId, Fp, model_call, Request, spend-RunId, Now, Call),
    effect_persist_put_call(Call).

%% -- combined world facts ----------------------------------------------------
facts(Facts) :-
    lease_facts(L),
    effect_facts(E),
    append(L, E, Facts).

%% -- helpers -----------------------------------------------------------------
now(T) :-
    get_time(T).

key(lease, Repo-PR, Id) :-
    format(atom(Id), 'lease:~w:~w', [Repo, PR]).
key(effect, Repo-PR-Sha-Action, Id) :-
    format(atom(Id), 'effect:~w:~w:~w:~w', [Repo, PR, Sha, Action]).
key(seen, EventKey, Id) :-
    format(atom(Id), 'seen:~w', [EventKey]).
key(cursor, Repo, Id) :-
    format(atom(Id), 'cursor:~w', [Repo]).
key(lease_index, idx, Id) :-
    format(atom(Id), 'lease-index', []).

fingerprint(Term, Hex) :-
    term_to_atom(Term, Atom),
    atom_codes(Atom, Codes),
    sha_hash(Codes, Hash, [algorithm(sha256)]),
    hex_bytes(Hex, Hash).

effect_call(CallId, Fp, Kind, Request, LogicalKey, Now,
            effect_call{call_id:CallId, fingerprint:Fp, kind:Kind,
                        request:Request, logical_key:LogicalKey,
                        created_at:Now}).

last([X], X) :- !.
last([_ | T], X) :-
    last(T, X).
