/* bin/copilot-service.pl — daemon entry point.

   Usage:
     FORGEJO_URL=... FORGEJO_TOKEN=... \
       swipl -s bin/copilot-service.pl -- \
         [--once|--forever] --repo Owner/Name [--repo ...] \
         [--state-dir Dir] [--poll-seconds N] [--model-step Module:Pred4]

   --once: resume paused runs, poll every watched repository once, exit 0.
   --forever: resume paused runs, then poll in a catch-and-continue loop
   every --poll-seconds (default 30).
*/

:- prolog_load_context(source, File),
   file_directory_name(File, BinDir),
   format(atom(RepoRoot), '~w/..', [BinDir]),
   assertz(user:file_search_path(service_bin, BinDir)),
   assertz(user:file_search_path(service_root, RepoRoot)),
   true.

:- use_module(service_root('test/loader.pl')).

:- initialization(main, main).

main(Argv) :-
    fcopilot_loader:setup_paths,
    fcopilot_loader:load_copilot,
    use_module(fcopilot(copilot_daemon)),
    copilot_daemon:daemon_main(Argv).
