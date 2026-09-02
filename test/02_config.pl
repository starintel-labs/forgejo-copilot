/* .copilot parser — ported invariant: config semantics (base-HEAD-only
   reads are enforced by the caller, not the parser; the parser turns file
   bytes into the closed effective-config dict defined by the spec). */

:- use_module(fcopilot_spec(forgejo_copilot_spec)).
:- use_module(fcopilot(copilot_config)).

:- begin_tests(config_parse).

test(absent_file_yields_disabled_defaults) :-
    copilot_config:parse(none, C),
    C == config{enabled:false, model:fast, auto:true, tasks:true}.

test(enabled_true_minimal) :-
    copilot_config:parse("enabled: true\n", C),
    C == config{enabled:true, model:fast, auto:true, tasks:true}.

test(presence_without_enabled_means_opt_in) :-
    copilot_config:parse("model: strong\n", C),
    C.enabled == true,
    C.model == strong.

test(explicit_opt_out_wins) :-
    copilot_config:parse("enabled: false\nmodel: strong\n", C),
    C == config{enabled:false, model:strong, auto:true, tasks:true}.

test(comments_and_blank_lines_ignored) :-
    copilot_config:parse("# opt in\n\nenabled: true\n# model: strong\n", C),
    C == config{enabled:true, model:fast, auto:true, tasks:true}.

test(all_keys) :-
    copilot_config:parse(
        "enabled: true\nmodel: strong\nauto: false\ntasks: false\n", C),
    C == config{enabled:true, model:strong, auto:false, tasks:false}.

test(unknown_keys_ignored) :-
    copilot_config:parse("enabled: true\nfuture_key: whatever\n", C),
    C == config{enabled:true, model:fast, auto:true, tasks:true}.

test(bad_value_fails_closed_to_disabled) :-
    copilot_config:parse("enabled: maybe\n", C),
    C.enabled == false.

test('crlf tolerated') :-
    copilot_config:parse("enabled: true\r\nmodel: strong\r\n", C),
    C == config{enabled:true, model:strong, auto:true, tasks:true}.

test(oversized_file_fails_closed) :-
    length(Chunk, 8192),
    maplist(=('a'), Chunk),
    atom_chars(A, Chunk),
    atom_concat('enabled: true\n', A, Big),
    copilot_config:parse(Big, C),
    C.enabled == false.

:- end_tests(config_parse).
