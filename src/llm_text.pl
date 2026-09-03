:- module(llm_text,
          [ strip_code_fences/2,
            structured_from_text/3,
            nonempty_text/1
          ]).

/** <module> Model text hygiene and structured decode

Host-side helpers for treating model output as untrusted text. The module
is deliberately portable: it depends only on `library(lists)` and the
closed schema algebra exported by `rlm_chain`, so it can be lifted into
the prolog-rlm tree unchanged.

  * strip_code_fences(+Text, -Stripped) — when the whole text is wrapped
    in ONE markdown fenced block (an opening ``` or ```lang line and a
    closing ``` line), the fence is removed; any other text is returned
    unchanged. Inner content is preserved byte-for-byte, including its
    own trailing newline.
  * structured_from_text(+Text, +SchemaSpec, -Value) — fence-strip, then
    decode and validate against the closed schema algebra. Semidet: any
    mismatch (invalid JSON, unexpected fields, type errors) is a plain
    failure; rejection is data, never an exception.
  * nonempty_text(+Text) — semidet; rejects the empty string.
*/

:- use_module(library(rlm_chain)).
:- use_module(library(lists)).

%% strip_code_fences(+Text, -Stripped) is det.
strip_code_fences(Text0, Stripped) :-
    text_string(Text0, Str),
    (   fenced_block(Str, Inner)
    ->  Stripped = Inner
    ;   Stripped = Str
    ).

%% fenced_block(+Str, -Inner) is semidet.
% The fence must span the whole text: the first line opens it (```,
% optionally followed by an info-string tag) and the last non-blank line
% closes it. Whitespace-only lines after the closing fence are ignored.
fenced_block(Str, Inner) :-
    split_string(Str, "\n", "\r", Lines0),
    trim_trailing_blank_lines(Lines0, [Open | Rest]),
    Rest \== [],
    fence_open(Open),
    append(Middle, [Close], Rest),
    Close == "```",
    !,
    atomic_list_concat(Middle, '\n', Inner0),
    text_string(Inner0, Inner).

fence_open(Open) :-
    sub_string(Open, 0, 3, Tag, "```"),
    \+ sub_string(Tag, _, _, _, "```").

trim_trailing_blank_lines(Lines, Trimmed) :-
    reverse(Lines, Rev),
    trim_blank_lines(Rev, RevTrimmed),
    reverse(RevTrimmed, Trimmed).

trim_blank_lines([Line | Lines], Trimmed) :-
    blank_line(Line),
    !,
    trim_blank_lines(Lines, Trimmed).
trim_blank_lines(Lines, Lines).

blank_line(Line) :-
    string_codes(Line, Codes),
    forall(member(Code, Codes), memberchk(Code, [32, 9, 13])).

%% structured_from_text(+Text, +SchemaSpec, -Value) is semidet.
structured_from_text(Text0, SchemaSpec, Value) :-
    strip_code_fences(Text0, Text),
    structured_schema_compile(SchemaSpec, ok(Schema)),
    structured_decode_validate(Schema, Text, ok(Value)).

%% nonempty_text(+Text) is semidet.
nonempty_text(Text) :-
    text_string(Text, Str),
    Str \== "".

text_string(Text, Str) :- string(Text), !, Str = Text.
text_string(Text, Str) :- atom(Text), !, atom_string(Text, Str).
