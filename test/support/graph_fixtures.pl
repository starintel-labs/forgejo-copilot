:- module(graph_fixtures,
          [ initial_state/2,
            task_chain/1,
            review_chain/1,
            log_nodes/2
          ]).

:- use_module(library(lists)).

initial_state(Route, state{data:run_data{delegate:stub_delegate,
                                         route:Route}}).

task_chain([received, config_checked, leased, fetched, partitioned,
            planned, branched, implemented, tested, pushed, pr_opened,
            replied]).

review_chain([partitioned, reviewed, deduped, posted]).

log_nodes(Log, Chain) :-
    findall(N,
            (   member(Entry, Log),
                compound(Entry),
                Entry = node-N
            ),
            Chain).
