:- module(plan_items,
          [ decode_plan/3,
            max_plan_items/1,
            safe_relative_path/1
          ]).

/** <module> Change-plan expert

Turns raw model output into the closed change-plan vocabulary the
delegate executes: a list of `change{path, change, message}` dicts with
atom fields and repo-relative paths.

This is the copilot expert over llm_text's generic decode bridge. The
portable pattern — model text -> fence strip -> closed schema -> authority
checks -> normalized domain term — is exactly what a prolog-rlm "expert"
looks like, so this module is the template to lift back upstream.

Authority: a plan item may only name a SAFE RELATIVE path (non-empty, no
leading `/`, no `..` or `.` component, no empty component). The plan is
bounded (max_plan_items/1) and must be non-empty; anything else fails and
the run routes to the visible-failure terminal.
*/

:- use_module(llm_text).
:- use_module(library(lists)).

max_plan_items(16).

plan_schema(list(object([field(path, string, required),
                         field(change, string, required),
                         field(message, string, required)]))).

%% decode_plan(+ModelText, +MaxItems, -Plan) is semidet.
decode_plan(ModelText, MaxItems, Plan) :-
    plan_schema(SchemaSpec),
    llm_text:structured_from_text(ModelText, SchemaSpec, Decoded),
    Decoded \== [],
    length(Decoded, N),
    N =< MaxItems,
    maplist(plan_item, Decoded, Plan).

%% plan_item(+Decoded, -Item) is semidet.
plan_item(Item, change{path:Path, change:Change, message:Message}) :-
    get_dict(path, Item, Path0),
    get_dict(change, Item, Change0),
    get_dict(message, Item, Message0),
    atom_string(Path, Path0),
    atom_string(Change, Change0),
    atom_string(Message, Message0),
    safe_relative_path(Path).

%% safe_relative_path(+Path) is semidet.
safe_relative_path(Path) :-
    text_to_string(Path, Str),
    Str \== "",
    \+ sub_string(Str, 0, 1, _, "/"),
    split_string(Str, "/", "", Components),
    forall(member(Component, Components),
           \+ memberchk(Component, ["", ".", ".."])).
