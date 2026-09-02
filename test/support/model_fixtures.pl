:- module(model_fixtures,
          [ cfg/1,
            fake_call/5,
            chain_options/2,
            e401/1,
            e429/1,
            e503/1,
            etr/1,
            e400/2
          ]).

/** <module> Model test fixtures */

:- use_module(library(lists)).

cfg(config{enabled:true, model:fast, auto:true, tasks:true}).

fake_call(Table, Step, _Request, _Extra, Outcome) :-
    get_dict(name, Step, Name),
    (   member(Name-Out, Table)
    ->  Outcome = Out
    ;   Outcome = error(provider_error{status:400, from:Name})
    ).

chain_options(Table, Options) :-
    chain3(Steps),
    Options = [steps(Steps),
               step_call(model_fixtures:fake_call(Table))].

chain3(Steps) :-
    maplist(mk_step,
            [openrouter_primary, openrouter_alternate, fallback_endpoint],
            Steps).

mk_step(Name, step{name:Name, model:Name, provider:none}).

e401(error(provider_error{status:401})).
e429(error(provider_error{status:429})).
e503(error(provider_error{status:503})).
etr(error(provider_error{status:transport})).
e400(From, error(provider_error{status:400, from:From})).
