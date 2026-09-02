:- module(web_tools,
          [ load_tool_pack/2,
            handler/3,
            guard_url/2
          ]).

/** <module> Web research tool pack

`brave_search` queries the Brave Search API with the `BRAVE_API_KEY`
credential. `web_fetch` retrieves the text of a public HTTPS page for
research grounding — restricted to public addresses (no loopback, private,
or link-local hosts, no credentials in the URL) so the bot's network
authority never reaches internal infrastructure.

Loading registers tool contracts and handlers and grants no capabilities.
*/

:- use_module(library(lists)).
:- use_module(library(http/http_open)).
:- use_module(library(http/json)).
:- use_module(fcopilot_spec(forgejo_copilot_spec)).

:- multifile rlm_tool_loader:tool_pack/2.
rlm_tool_loader:tool_pack(web, web_tools:load_tool_pack).

%% load_tool_pack(+Registry, -Outcome) is det.
load_tool_pack(Registry, ok(registered)) :-
    !,
    forall(spec_tool_names(web, Name),
           (   tool_def(Name, Schema, Handler),
               rlm_tool:tool_register(Registry, Schema, Handler, ok(_))
           )).
load_tool_pack(_Registry, error(pack_already_loaded)).

tool_def(Name, Schema, web_tools:handler(Name)) :-
    spec_tool(web, Name, Effect, Limits),
    get_dict(time_limit, Limits, TimeLimit),
    get_dict(max_output_bytes, Limits, MaxOutputBytes),
    args_schema(Name, Arguments, Result),
    description(Name, Description),
    Schema = tool_schema{name:Name,
                         description:Description,
                         capability:tool(Name),
                         effect:Effect,
                         arguments:Arguments,
                         result:Result,
                         limits:tool_limits{time_limit:TimeLimit,
                                            max_output_bytes:MaxOutputBytes}}.

description(brave_search, "Search the public web (Brave) for grounding evidence").
description(web_fetch, "Fetch the text of one public HTTPS page").

args_schema(brave_search,
            _{ type:object,
               required:[query],
               additional_properties:false,
               properties:_{
                   query:_{type:string},
                   count:_{type:integer, minimum:1, maximum:10}
               }},
            _{ type:object,
               required:[results],
               additional_properties:false,
               properties:_{results:_{type:list}}}).

args_schema(web_fetch,
            _{ type:object,
               required:[url],
               additional_properties:false,
               properties:_{
                   url:_{type:string}
               }},
            _{ type:object,
               required:[text],
               additional_properties:false,
               properties:_{text:_{type:string}}}).

% -- handler ------------------------------------------------------------------

handler(brave_search, Args, _{results:Results}) :-
    !,
    brave_config(Config),
    get_dict(query, Args, Query),
    format_query(Query, Encoded),
    (   get_dict(count, Args, Count)
    ->  true
    ;   Count = 5
    ),
    format(atom(Url),
           'https://api.search.brave.com/res/v1/web/search?q=~w&count=~w',
           [Encoded, Count]),
    http_open(Url, Stream,
              [method(get),
               request_header('X-Subscription-Token'=Config.token),
               request_header('Accept'='application/json'),
               timeout(15)]),
    set_stream(Stream, encoding(utf8)),
    catch(json_read_dict(Stream, Json), _, Json = _{}),
    close(Stream),
    (   get_dict(web, Json, Web),
        get_dict(results, Web, Results0)
    ->  true
    ;   Results0 = []
    ),
    take(Results0, Count, Results).

handler(web_fetch, Args, _{text:Text}) :-
    !,
    get_dict(url, Args, Url),
    guard_url(Url, UrlAtom),
    http_open(UrlAtom, Stream,
              [method(get), timeout(20),
               request_header('Accept'='text/plain, text/html;q=0.9, */*;q=0.5')]),
    set_stream(Stream, encoding(utf8)),
    read_all(Stream, Codes),
    close(Stream),
    atom_codes(Text, Codes).

handler(_Name, _Args, _Value) :-
    throw(web_config_error("handler configuration error")).

brave_config(config{token:Token}) :-
    getenv('BRAVE_API_KEY', Token),
    Token \== ''.

format_query(Query, Encoded) :-
    text_to_string(Query, Str),
    uri_encoded(query_value, Str, Encoded).

%% guard_url(+Url, -UrlAtom) is semidet.
% Public HTTPS URLs only. Rejects (throwing a structured
% web_url_guard_error) non-https schemes, IP literals in non-public
% ranges, localhost-style hosts, and URLs with userinfo.
guard_url(Url, UrlAtom) :-
    text_to_string(Url, S),
    (   parse_scheme_host(S, https, Host, _Port)
    ->  true
    ;   throw(web_url_guard_error(S, "https required"))
    ),
    (   private_host(Host)
    ->  throw(web_url_guard_error(S, "non-public host"))
    ;   true
    ),
    atom_string(UrlAtom, S).

parse_scheme_host(S, Scheme, Host, Port) :-
    split_string(S, ":", "", [SchemeS, Rest]),
    downcase_atom(SchemeS, Lower),
    downcase_atom(Scheme, Lower),
    string_concat("//", AfterSlashes, Rest),
    split_string(AfterSlashes, "/", "", [HostPort | _Path]),
    \+ sub_string(HostPort, _, _, _, "@"),
    (   split_string(HostPort, ":", "", [HostS, PortS])
    ->  number_string(Port, PortS)
    ;   split_string(HostPort, ":", "", [HostS]),
        Port = none
    ),
    atom_string(Host, HostS).

private_host(Host) :-
    (   ip_literal(Host, A-B-C-D)
    ->  private_ip4(A, B, C, D)
    ;   local_name(Host)
    ).

% Denylist of non-public IPv4 ranges (also covers CGNAT, multicast,
% reserved, and unspecified). Hostnames are checked by name below.
private_ip4(0, _, _, _).
private_ip4(10, _, _, _).
private_ip4(100, B, _, _) :- B >= 64, B =< 127.
private_ip4(127, _, _, _).
private_ip4(169, 254, _, _).
private_ip4(172, B, _, _) :- B >= 16, B =< 31.
private_ip4(192, 168, _, _).
private_ip4(A, _, _, _) :- A >= 224.

local_name(Host) :-
    downcase_atom(Host, H),
    (   sub_atom(H, _, _, _, 'localhost')
    ;   sub_atom(H, _, 6, 0, '.local')
    ;   sub_atom(H, 0, 1, _, '.')
    ).

ip_literal(Host, A-B-C-D) :-
    split_string(Host, ".", "", Parts),
    Parts = [AS, BS, CS, DS],
    maplist(atom_number, [AS, BS, CS, DS], [A, B, C, D]).

read_all(Stream, Codes) :-
    read_codes(Stream, Codes, 0, 524288).

read_codes(Stream, Codes, N, Max) :-
    N =< Max,
    (   get_code(Stream, C),
        C \== -1
    ->  Codes = [C | Rest],
        N2 is N + 1,
        read_codes(Stream, Rest, N2, Max)
    ;   Codes = []
    ).

take(List, N, Taken) :-
    length(Prefix, N),
    (   append(Prefix, _, List)
    ->  Taken = Prefix
    ;   Taken = List
    ).
