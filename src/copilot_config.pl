:- module(copilot_config,
          [ parse/2,
            parse_bytes/2
          ]).

/** <module> .copilot file parser

Turns `.copilot` file bytes into the closed effective configuration dict
defined by `forgejo_copilot_spec`. The caller is responsible for reading the
file from the PR base branch HEAD only.

Fails closed: anything malformed, oversized, or with a bad value for a
boolean key disables the bot rather than guessing an enabling configuration.
Unknown keys are ignored (forward compatible). Comments start with `#`.
*/

:- use_module(fcopilot_spec(forgejo_copilot_spec)).
:- use_module(library(lists)).

max_copilot_bytes(4096).

%% parse(+FileSpec, -Config) is det.
% FileSpec is `none` (file absent at the base HEAD) or the file text as a
% string/atom/codes.
parse(none, Config) :-
    !,
    spec_config_effective(none, Config).
parse(Text, Config) :-
    text_to_string(Text, Str),
    string_length(Str, N),
    (   N =< 4096,
        pairs_from_text(Str, Pairs0),
        Pairs0 \== malformed
    ->  spec_config_effective(Pairs0, Config)
    ;   spec_config_effective(none, Config)
    ).

%% parse_bytes(+Bytes, -Config) is det.
parse_bytes(Bytes, Config) :-
    (   length(Bytes, N),
        N =< 4096
    ->  phrase(utf8_codes(Codes), Bytes),
        atom_codes(Atom, Codes),
        parse(Atom, Config)
    ;   spec_config_effective(none, Config)
    ).

% -- internal ---------------------------------------------------------------

pairs_from_text(Str, Pairs) :-
    split_string(Str, "\n", "\r", Lines),
    parse_lines(Lines, Pairs0),
    (   memberchk(malformed, Pairs0)
    ->  Pairs = malformed
    ;   Pairs = Pairs0
    ).

parse_lines([], []).
parse_lines([Line | Rest], Pairs) :-
    (   line_action(Line, skip)
    ->  Pairs = PairsRest
    ;   line_action(Line, Pair)
    ->  Pairs = [Pair | PairsRest]
    ;   Pairs = [malformed | PairsRest]
    ),
    parse_lines(Rest, PairsRest).

% A blank line or a line whose pre-comment part is blank is skipped.
line_action(Line, skip) :-
    \+ significant(Line),
    !.
% A recognized key with a shape-valid value produces a pair. Unknown keys
% are skipped (forward compatible); bad values fail the line (malformed).
line_action(Line, pairs(Key, Value)) :-
    significant(Line),
    precomment(Line, Before),
    split_string(Before, ":", " \t", [KeyS, ValueS]),
    downcase_atom_key(KeyS, Key),
    known_key(Key),
    value_term(Key, ValueS, Value).
% A well-formed line with an unknown key is skipped (forward compatible).
line_action(Line, skip) :-
    significant(Line),
    precomment(Line, Before),
    split_string(Before, ":", " \t", [KeyS, ValueS]),
    downcase_atom_key(KeyS, Key),
    ValueS \== "",
    \+ known_key(Key),
    !.

significant(Line) :-
    precomment(Line, Before),
    has_nonspace(Before).

precomment(Line, Before) :-
    (   sub_string(Line, I, _, _, "#")
    ->  sub_string(Line, 0, I, _, Before)
    ;   Before = Line
    ).

has_nonspace(Str) :-
    string_codes(Str, Codes),
    member(C, Codes),
    \+ memberchk(C, [32, 9, 13, 10]),
    !.

downcase_atom_key(KeyS, Key) :-
    atom_string(Atom0, KeyS),
    downcase_atom(Atom0, Key).

known_key(Key) :-
    spec_copilot_key(Key).

value_term(enabled, ValueS, Value) :-
    boolean_value(ValueS, Value).
value_term(auto, ValueS, Value) :-
    boolean_value(ValueS, Value).
value_term(tasks, ValueS, Value) :-
    boolean_value(ValueS, Value).
value_term(model, ValueS, Value) :-
    ValueS \== "",
    atom_string(Value, ValueS).

boolean_value(ValueS, Value) :-
    string_lower(ValueS, Lower),
    (   member(Lower, ["true", "yes"])
    ->  Value = true
    ;   member(Lower, ["false", "no"])
    ->  Value = 'false'
    ).

string_lower(S, L) :-
    atom_string(A, S),
    downcase_atom(A, A2),
    atom_string(A2, L).

% utf8_codes/1 grammar for parse_bytes
utf8_codes([]) --> [].
utf8_codes([C | Cs]) --> [C], { integer(C) }, utf8_codes(Cs).
