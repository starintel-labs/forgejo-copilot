/* Tool packs — loading via rlm_tool_loader, schema/ceiling conformance
   with the formal spec, capability denial, and pure request-mapping
   helpers. Deterministic: no network I/O in any test. */

:- use_module(fcopilot_spec(forgejo_copilot_spec)).
:- use_module(fcopilot(forgejo), []).
:- use_module(fcopilot(web), []).
:- use_module(fcopilot(admission), []).
:- use_module(library(rlm)).
:- use_module(library(rlm_tool_loader)).

:- begin_tests(pack_loading).

test(packs_are_declared) :-
    rlm_tool_loader:rlm_tool_packs(Packs),
    memberchk(forgejo, Packs),
    memberchk(web, Packs).

test(forgejo_pack_loads_all_spec_tools) :-
    rlm_tool:tool_registry_create(Registry),
    setup_call_cleanup(
        rlm_tool_loader:rlm_load_tools(Registry, forgejo, ok(_)),
        (   rlm_tool:tool_discover(Registry, Schemas),
            findall(Name,
                    (   member(S, Schemas),
                        get_dict(name, S, Name)
                    ),
                    Names),
            sort(Names, Sorted),
            findall(T, spec_tool_names(forgejo, T), Targets0),
            sort(Targets0, Targets),
            Sorted == Targets
        ),
        rlm_tool:tool_registry_destroy(Registry)).

test(web_pack_loads_all_spec_tools) :-
    rlm_tool:tool_registry_create(Registry),
    setup_call_cleanup(
        rlm_tool_loader:rlm_load_tools(Registry, web, ok(_)),
        (   rlm_tool:tool_discover(Registry, Schemas),
            findall(Name,
                    (   member(S, Schemas),
                        get_dict(name, S, Name)
                    ),
                    Names),
            sort(Names, Sorted),
            findall(T, spec_tool_names(web, T), Targets0),
            sort(Targets0, Targets),
            Sorted == Targets
        ),
        rlm_tool:tool_registry_destroy(Registry)).

test(ceilings_and_effects_match_spec) :-
    rlm_tool:tool_registry_create(Registry),
    setup_call_cleanup(
        rlm_tool_loader:rlm_load_all_tools(Registry, ok(_)),
        (   rlm_tool:tool_discover(Registry, Schemas),
            forall(member(S, Schemas),
                   (   get_dict(name, S, Name),
                       (   spec_tool(forgejo, Name, Effect, Limits)
                       ;   spec_tool(web, Name, Effect, Limits)
                       ),
                       get_dict(effect, S, Effect),
                       get_dict(limits, S, SL),
                       get_dict(time_limit, Limits, T),
                       get_dict(time_limit, SL, T),
                       get_dict(max_output_bytes, Limits, B),
                       get_dict(max_output_bytes, SL, B)
                   ))
        ),
        rlm_tool:tool_registry_destroy(Registry)).

test(capabilities_are_separate_from_loading) :-
    rlm_tool:tool_registry_create(Registry),
    setup_call_cleanup(
        rlm_tool_loader:rlm_load_tools(Registry, forgejo, ok(_)),
        (   rlm_tool:tool_invoke(Registry, [], get_issue,
                                 _{owner:o, repo:r, index:1},
                                 [], Outcome, _Trace),
            Outcome = error(E),
            get_dict(kind, E, capability_denied),
            get_dict(tool, E, get_issue)
        ),
        rlm_tool:tool_registry_destroy(Registry)).

test(malformed_arguments_fail_at_schema) :-
    rlm_tool:tool_registry_create(Registry),
    setup_call_cleanup(
        rlm_tool_loader:rlm_load_tools(Registry, forgejo, ok(_)),
        (   rlm_tool:tool_invoke(Registry,
                                 [tool(get_issue)],
                                 get_issue,
                                 _{owner:o},
                                 [], Outcome, _Trace),
            Outcome = error(E),
            get_dict(kind, E, schema_validation_failed)
        ),
        rlm_tool:tool_registry_destroy(Registry)).

:- end_tests(pack_loading).

:- begin_tests(forgejo_request_mapping).

test(request_specs) :-
    forgejo_tools:request_spec(get_issue, _{owner:o, repo:r, index:7},
                               get, 'repos/o/r/issues/7', none),
    forgejo_tools:request_spec(get_diff, _{owner:o, repo:r, index:7},
                               get, 'repos/o/r/pulls/7.diff', none),
    forgejo_tools:request_spec(create_pr,
                               _{owner:o, repo:r, title:T, head:H, base:B},
                               post, 'repos/o/r/pulls',
                               _{title:T, head:H, base:B}).

test(review_event_mapping) :-
    forgejo_tools:request_spec(post_pr_review,
                               _{owner:o, repo:r, index:1,
                                 event:approve, body:"lgtm"},
                               post, 'repos/o/r/pulls/1/reviews',
                               _{body:"lgtm", event:'APPROVED'}).

test(build_url) :-
    forgejo_tools:build_url('https://git.example.com/api/v1',
                            'repos/o/r/issues', Url),
    Url == 'https://git.example.com/api/v1/repos/o/r/issues'.

test(push_commit_create_vs_update) :-
    forgejo_tools:request_spec(
        push_commit,
        _{owner:o, repo:r, branch:'copilot/x', path:'src/a.pl',
          content_b64:'QUJD', message:'copilot: add'},
        post, 'repos/o/r/contents/src/a.pl',
        _{branch:'copilot/x', content:'QUJD', message:'copilot: add'}),
    forgejo_tools:request_spec(
        push_commit,
        _{owner:o, repo:r, branch:'copilot/x', path:'src/a.pl',
          content_b64:'QUJD', message:'copilot: fix', sha:'abc123'},
        put, 'repos/o/r/contents/src/a.pl',
        _{branch:'copilot/x', content:'QUJD', message:'copilot: fix',
          sha:'abc123'}).

:- end_tests(forgejo_request_mapping).

:- begin_tests(web_url_guard).

guard_rejects(Url) :-
    (   catch(web_tools:guard_url(Url, _), _, false)
    ->  fail
    ;   true
    ).

test(https_required) :-
    guard_rejects('http://example.com/x').

test(public_https_accepted) :-
    web_tools:guard_url('https://example.com/docs/page', U),
    U == 'https://example.com/docs/page'.

test(private_ranges_rejected) :-
    guard_rejects('https://127.0.0.1/secret'),
    guard_rejects('https://10.1.2.3/internal'),
    guard_rejects('https://192.168.1.1/router'),
    guard_rejects('https://172.16.0.9/x'),
    guard_rejects('https://169.254.169.254/metadata'),
    guard_rejects('https://100.64.0.1/x').

test(localhost_names_rejected) :-
    guard_rejects('https://localhost:3000/x'),
    guard_rejects('https://host.local/x').

test(userinfo_rejected) :-
    guard_rejects('https://user:pass@example.com/x').

:- end_tests(web_url_guard).
