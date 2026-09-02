kb_task(t_spec, done, 'main-build', 'formal spec: spec/forgejo_copilot_spec.pl').
kb_task(t_tests, in_progress, 'main-build', 'PlUnit suite porting invariants').
kb_task(t_verify, pending, 'main-build', 'verify script: spec conformance (verify/verify.pl)').
kb_task(t_smoke, pending, 'main-build', 'credential-free smoke demo').
kb_task(t_config, done, 'main-build', 'src/copilot_config.pl green 10/10').
kb_task(t_gate, done, 'main-build', 'admission+journal+event green 21/21').
kb_task(t_graph, done, 'main-build', 'rlm_graph realization green 8/8; gate 68/68').
kb_task(t_models, done, 'main-build', 'model strategy + downgrade chain green 12/12').
kb_task(t_pack_forgejo, done, 'main-build', 'forgejo+web packs green 15/15; ceilings match spec').
kb_task(t_service, done, 'main-build', 'pipeline committed c3072f2').
kb_task(t_pack_web, done, 'main-build', 'web pack green').
kb_task(t_restart, in_progress, 'resume-continuation', 'continuation session: un-park 07, debug fresh-process resume').
kb_dep(t_tests, t_spec).
kb_dep(t_config, t_tests).
kb_dep(t_gate, t_config).
kb_dep(t_pack_forgejo, t_tests).
kb_dep(t_pack_web, t_tests).
kb_dep(t_graph, t_tests).
kb_dep(t_models, t_tests).
kb_dep(t_service, t_gate).
kb_dep(t_service, t_pack_forgejo).
kb_dep(t_service, t_graph).
kb_dep(t_service, t_models).
kb_dep(t_verify, t_tests).
kb_dep(t_restart, t_graph).
kb_dep(t_smoke, t_service).
kb_event(1788375462.2998836, 'main-build', 'test gate green: 29 spec tests; starting t_config').
kb_event(1788386153.6421485, 'main-build', 'HANDOFF: gate 95/95 with 07 parked; next session continues from HANDOFF.md').
kb_event(1788387445.809784, 'resume-continuation', 'continuation session started; PROLOG_RLM_HOME=~/Documents/Projects/prolog-rlm main@156bfe9; gate 95/95 confirmed').
kb_evidence(t_spec, '30/30 invariant battery pass', 'Prolog MCP session cb0808bce0d1').
