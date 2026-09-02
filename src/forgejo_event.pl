:- module(forgejo_event,
          [ is_bot_actor/2,
            event_kind/4,
            event_command/2,
            to_spec_event/4
          ]).

/** <module> Forgejo event translation

Maps polled Forgejo payload fields (actor login, actor bot flag, comment
body) into the closed `event{}` terms the spec admission gate consumes.

Classification:
  * mention  — the body contains the word `@copilot` (case-insensitive)
  * command  — the body's FIRST word is `/review` or `/ask`
  * pr_opened — synthesized by the poller for newly opened PRs

The bot self-loop guard is enforced downstream by the gate; this module
only classifies.
*/

:- use_module(library(lists)).

%% is_bot_actor(+Login, +BotFlagFromApi) is semidet.
% Succeeds when the actor IS a bot. The API bot flag wins; the name
% heuristic covers common bot naming when the flag is absent.
is_bot_actor(_Login, true) :- !.
is_bot_actor(Login, false) :-
    bot_name(Login).

bot_name(Login) :-
    downcase_atom(Login, L),
    sub_atom(L, _, _, _, '[bot]').
bot_name(Login) :-
    downcase_atom(Login, L),
    sub_atom(L, _, _, _, 'copilot').

%% event_kind(+Login, +BotFlag, +Body, -Kind) is semidet.
event_kind(Login, BotFlag, Body, mention) :-
    \+ is_bot_actor(Login, BotFlag),
    body_has_word(Body, '@copilot'),
    !.
event_kind(Login, BotFlag, Body, command) :-
    \+ is_bot_actor(Login, BotFlag),
    (   body_first_word(Body, '/review')
    ;   body_first_word(Body, '/ask')
    ),
    !.

%% event_command(+Body, -Command) is semidet.
event_command(Body, '/review') :-
    body_first_word(Body, '/review'),
    !.
event_command(Body, '/ask') :-
    body_first_word(Body, '/ask'),
    !.
event_command(_Body, none).

%% to_spec_event(+Login, +BotFlag, +Body, -Event) is semidet.
to_spec_event(Login, BotFlag, Body, Event) :-
    event_kind(Login, BotFlag, Body, mention),
    !,
    Event = event{actor:Login, actor_kind:actor_kind(BotFlag),
                  kind:mention, body:Body}.
to_spec_event(Login, BotFlag, Body, Event) :-
    event_kind(Login, BotFlag, Body, command),
    !,
    event_command(Body, Command),
    Event = event{actor:Login, actor_kind:actor_kind(BotFlag),
                  kind:command, command:Command}.

actor_kind(true) :- !, bot.
actor_kind(false) :- human.

% -- internals ---------------------------------------------------------------

body_has_word(Body, Token) :-
    body_words(Body, Words),
    member(Word, Words),
    word_matches(Word, Token).

body_first_word(Body, Token) :-
    body_words(Body, [Word | _]),
    word_matches(Word, Token).

body_words(Body, Words) :-
    text_to_string(Body, Str),
    split_string(Str, " \t\r\n", " \t\r\n", Words0),
    exclude(=(""), Words0, Words).

word_matches(Word, Token) :-
    string_lower(Word, WLower),
    downcase_atom(Token, TokenAtom),
    atom_string(TokenAtom, TokenStr),
    WLower == TokenStr.

string_lower(S, L) :-
    atom_string(A, S),
    downcase_atom(A, A2),
    atom_string(A2, L).
