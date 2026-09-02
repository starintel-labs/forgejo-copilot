:- module(fcopilot_loader,
          [ load_all/0,
            load_runtime/0,
            load_copilot/0,
            setup_paths/0,
            summary_ok/1,
            runner_dir/1
          ]).

/** <module> Test and entry-point loader

Resolves the prolog-rlm runtime in either of two ways, in order:

1. `SWIPL_PACK_PATH` containing an installed `prolog_rlm` pack (the nix
   devShell does this), so `library(rlm)` works directly;
2. the `PROLOG_RLM_HOME` environment variable pointing at a prolog-rlm
   checkout, whose `prolog/` directory is added to the library search path.

Project sources are exposed under the file-search aliases `fcopilot`
(src and packs) and `fcopilot_spec` (spec).
*/

:- use_module(library(lists)).

:- dynamic runner_dir/1.

setup_paths :-
    getenv('PROLOG_RLM_HOME', Home),
    !,
    format(atom(PrologDir), '~w/prolog', [Home]),
    (   user:file_search_path(library, PrologDir)
    ->  true
    ;   assertz(user:file_search_path(library, PrologDir))
    ),
    project_aliases.
setup_paths :-
    project_aliases.

% Captured once at load time: this file lives in <repo>/test.
:- prolog_load_context(source, LoaderFile),
   file_directory_name(LoaderFile, TestDir),
   format(atom(RepoRoot), '~w/..', [TestDir]),
   assertz(fcopilot_loader:repo_root(RepoRoot)),
   true.

project_aliases :-
    repo_root(RepoRoot),
    absolute_file_name(RepoRoot, Root, [file_type(directory)]),
    format(atom(SrcDir), '~w/src', [Root]),
    format(atom(PackDir), '~w/packs', [Root]),
    format(atom(SpecDir), '~w/spec', [Root]),
    forall(member(Dir-Alias, [SrcDir-fcopilot,
                              PackDir-fcopilot,
                              SpecDir-fcopilot_spec]),
           (   user:file_search_path(Alias, Dir)
           ->  true
           ;   assertz(user:file_search_path(Alias, Dir))
           )).

load_runtime :-
    setup_paths,
    use_module(library(rlm)).

load_copilot :-
    load_runtime,
    use_module(fcopilot(copilot_spec_bridge)),
    use_module(fcopilot(copilot_config)),
    use_module(fcopilot(admission)),
    use_module(fcopilot(copilot_graph)),
    use_module(fcopilot(model_strategy)),
    use_module(fcopilot(journal)),
    use_module(fcopilot(service)),
    use_module(fcopilot(forgejo_tools)),
    use_module(fcopilot(web_tools)).

load_all :-
    load_copilot.

summary_ok(Summary) :-
    get_dict(total, Summary, Total),
    get_dict(passed, Summary, Passed),
    get_dict(failed, Summary, Failed),
    get_dict(blocked, Summary, Blocked),
    (   nonvar(Total), nonvar(Passed), nonvar(Failed), nonvar(Blocked)
    ->  format('aggregate: total=~d passed=~d failed=~d blocked=~d~n',
               [Total, Passed, Failed, Blocked]),
        Total > 0,
        Passed =:= Total,
        Failed =:= 0,
        Blocked =:= 0
    ;   format(user_error, 'RUNNER: incomplete summary ~w~n', [Summary]),
        fail
    ).
