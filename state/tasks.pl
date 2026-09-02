kb_task(t_spec, done, 'main-build', 'formal spec: spec/forgejo_copilot_spec.pl').
kb_task(t_tests, in_progress, 'main-build', 'PlUnit suite porting invariants').
kb_task(t_pack_forgejo, pending, 'main-build', 'forgejo tool pack (packs/forgejo.pl)').
kb_task(t_pack_web, pending, 'main-build', 'web tool pack (packs/web.pl)').
kb_task(t_models, pending, 'main-build', 'model strategy + downgrade chain (src/model_strategy.pl)').
kb_task(t_service, pending, 'main-build', 'daemon + poll loop (src/service.pl)').
kb_task(t_verify, pending, 'main-build', 'verify script: spec conformance (verify/verify.pl)').
kb_task(t_restart, pending, 'main-build', 'fresh-process restart fixture').
kb_task(t_smoke, pending, 'main-build', 'credential-free smoke demo').
kb_task(t_config, done, 'main-build', 'src/copilot_config.pl green 10/10').
kb_task(t_gate, done, 'main-build', 'admission+journal+event green 21/21').
kb_task(t_graph, done, 'main-build', 'rlm_graph realization green 8/8; gate 68/68').
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
kb_evidence(t_spec, '30/30 invariant battery pass', 'Prolog MCP session cb0808bce0d1').
