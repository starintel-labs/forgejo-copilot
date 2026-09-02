:- module(forgejo_tools,
          [ load_tool_pack/2,
            handler/3,
            get_file_content/5,
            forgejo_config/1,
            build_url/3,
            request_spec/5
          ]).

/** <module> Forgejo tool pack

External prolog-rlm tool pack for the configured Forgejo REST API. Loading
registers tool contracts and handlers; it grants no capabilities. Model
output can select these tools only through a closed plan that already holds
the matching `tool(Name)` capability.

Network scope: these handlers talk ONLY to the base URL in `FORGEJO_URL`
with the `FORGEJO_TOKEN` credential. Without that configuration every
handler fails closed with a structured configuration error before any
network I/O. No shell, process, or filesystem capability exists in this
pack.
*/

:- use_module(library(lists)).
:- use_module(library(option)).
:- use_module(library(http/http_open)).
:- use_module(library(url)).
:- use_module(library(http/json)).
:- use_module(fcopilot_spec(forgejo_copilot_spec)).

:- multifile rlm_tool_loader:tool_pack/2.
rlm_tool_loader:tool_pack(forgejo, forgejo_tools:load_tool_pack).

%% load_tool_pack(+Registry, -Outcome) is det.
load_tool_pack(Registry, ok(registered)) :-
    !,
    forall(spec_tool_names(forgejo, Name),
           (   tool_def(Name, Schema, Handler),
               rlm_tool:tool_register(Registry, Schema, Handler, ok(_))
           )).
load_tool_pack(_Registry, error(Reason)) :-
    Reason = pack_already_loaded.

tool_def(Name, Schema, forgejo_tools:handler(Name)) :-
    spec_tool(forgejo, Name, Effect, Limits),
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

description(list_issues_updated_since,
            "List issues in a repo updated since an RFC3339 timestamp").
description(get_issue, "Read one issue with its body and metadata").
description(get_pr, "Read one pull request with branch and head info").
description(get_diff, "Read the raw diff of a pull request").
description(list_changed_files, "List the files changed by a pull request").
description(get_comment_thread, "Read the comments on an issue or PR").
description(post_issue_comment, "Post a comment on an issue or PR").
description(post_pr_review,
            "Post a line-anchored review (approve/request_changes/comment)").
description(create_branch, "Create a branch under the copilot/ namespace").
description(push_commit,
            "Create or update one file on a copilot/ branch (contents API)").
description(create_pr, "Open a pull request from a copilot/ branch").

% -- argument schemas ---------------------------------------------------------

owner_props(_{owner:_{type:string}, repo:_{type:string}}).

issue_index_props(_{index:_{type:integer, minimum:1}}).

args_schema(list_issues_updated_since,
            _{ type:object,
               required:[owner, repo, since],
               additional_properties:false,
               properties:_{
                   owner:_{type:string},
                   repo:_{type:string},
                   since:_{type:string},
                   page:_{type:integer, minimum:1},
                   limit:_{type:integer, minimum:1, maximum:50}
               }},
            _{ type:object,
               required:[issues],
               additional_properties:false,
               properties:_{issues:_{type:list}}}).

args_schema(get_issue,
            _{ type:object,
               required:[owner, repo, index],
               additional_properties:false,
               properties:_{
                   owner:_{type:string},
                   repo:_{type:string},
                   index:_{type:integer, minimum:1}
               }},
            _{ type:object,
               required:[issue],
               additional_properties:false,
               properties:_{issue:_{type:object}}}).

args_schema(get_pr,
            _{ type:object,
               required:[owner, repo, index],
               additional_properties:false,
               properties:_{
                   owner:_{type:string},
                   repo:_{type:string},
                   index:_{type:integer, minimum:1}
               }},
            _{ type:object,
               required:[pull],
               additional_properties:false,
               properties:_{pull:_{type:object}}}).

args_schema(get_diff,
            _{ type:object,
               required:[owner, repo, index],
               additional_properties:false,
               properties:_{
                   owner:_{type:string},
                   repo:_{type:string},
                   index:_{type:integer, minimum:1}
               }},
            _{ type:object,
               required:[diff],
               additional_properties:false,
               properties:_{diff:_{type:string}}}).

args_schema(list_changed_files,
            _{ type:object,
               required:[owner, repo, index],
               additional_properties:false,
               properties:_{
                   owner:_{type:string},
                   repo:_{type:string},
                   index:_{type:integer, minimum:1}
               }},
            _{ type:object,
               required:[files],
               additional_properties:false,
               properties:_{files:_{type:list}}}).

args_schema(get_comment_thread,
            _{ type:object,
               required:[owner, repo, index],
               additional_properties:false,
               properties:_{
                   owner:_{type:string},
                   repo:_{type:string},
                   index:_{type:integer, minimum:1}
               }},
            _{ type:object,
               required:[comments],
               additional_properties:false,
               properties:_{comments:_{type:list}}}).

args_schema(post_issue_comment,
            _{ type:object,
               required:[owner, repo, index, body],
               additional_properties:false,
               properties:_{
                   owner:_{type:string},
                   repo:_{type:string},
                   index:_{type:integer, minimum:1},
                   body:_{type:string}
               }},
            _{ type:object,
               required:[comment_id],
               additional_properties:false,
               properties:_{comment_id:_{type:integer}}}).

args_schema(post_pr_review,
            _{ type:object,
               required:[owner, repo, index, event, body],
               additional_properties:false,
               properties:_{
                   owner:_{type:string},
                   repo:_{type:string},
                   index:_{type:integer, minimum:1},
                   event:_{type:string,
                           enum:["approve", "request_changes", "comment"]},
                   body:_{type:string},
                   comments:_{type:list}
               }},
            _{ type:object,
               required:[review_id, event],
               additional_properties:false,
               properties:_{
                   review_id:_{type:integer},
                   event:_{type:string}
               }}).

args_schema(create_branch,
            _{ type:object,
               required:[owner, repo, new_branch, base_branch],
               additional_properties:false,
               properties:_{
                   owner:_{type:string},
                   repo:_{type:string},
                   new_branch:_{type:string},
                   base_branch:_{type:string}
               }},
            _{ type:object,
               required:[branch],
               additional_properties:false,
               properties:_{branch:_{type:object}}}).

args_schema(push_commit,
            _{ type:object,
               required:[owner, repo, branch, path, content_b64, message],
               additional_properties:false,
               properties:_{
                   owner:_{type:string},
                   repo:_{type:string},
                   branch:_{type:string},
                   path:_{type:string},
                   content_b64:_{type:string},
                   message:_{type:string},
                   sha:_{type:string}
               }},
            _{ type:object,
               required:[commit_sha],
               additional_properties:false,
               properties:_{commit_sha:_{type:string}}}).

args_schema(create_pr,
            _{ type:object,
               required:[owner, repo, title, head, base],
               additional_properties:false,
               properties:_{
                   owner:_{type:string},
                   repo:_{type:string},
                   title:_{type:string},
                   head:_{type:string},
                   base:_{type:string},
                   body:_{type:string}
               }},
            _{ type:object,
               required:[pr_index],
               additional_properties:false,
               properties:_{pr_index:_{type:integer}}}).

% -- pure request mapping (deterministically testable) ------------------------

%% forgejo_config(-Config) is semidet.
% Reads FORGEJO_URL/FORGEJO_TOKEN from the environment at request time.
forgejo_config(config{base:Base, token:Token}) :-
    getenv('FORGEJO_URL', Base),
    Base \== '',
    getenv('FORGEJO_TOKEN', Token).

%% build_url(+Base, +Path, -Url) is det.
build_url(Base, Path, Url) :-
    (   sub_atom(Base, _, _, 0, '/') -> Base2 = Base ; atom_concat(Base, '/', Base2) ),
    atom_concat(Base2, Path, Url).

%% request_spec(+Tool, +Args, -Method, -Path, -BodyJson) is det.
% BodyJson is `none` for reads.
request_spec(list_issues_updated_since, Args, get, Path, none) :-
    !,
    get_dict(owner, Args, Owner),
    get_dict(repo, Args, Repo),
    format(atom(Path), 'repos/~w/~w/issues', [Owner, Repo]),
    (   get_dict(since, Args, Since)
    ->  true
    ;   Since = ''
    ).
request_spec(get_issue, Args, get, Path, none) :-
    !,
    get_dict(owner, Args, Owner),
    get_dict(repo, Args, Repo),
    get_dict(index, Args, Index),
    format(atom(Path), 'repos/~w/~w/issues/~w', [Owner, Repo, Index]).
request_spec(get_pr, Args, get, Path, none) :-
    !,
    get_dict(owner, Args, Owner),
    get_dict(repo, Args, Repo),
    get_dict(index, Args, Index),
    format(atom(Path), 'repos/~w/~w/pulls/~w', [Owner, Repo, Index]).
request_spec(get_diff, Args, get, Path, none) :-
    !,
    get_dict(owner, Args, Owner),
    get_dict(repo, Args, Repo),
    get_dict(index, Args, Index),
    format(atom(Path), 'repos/~w/~w/pulls/~w.diff', [Owner, Repo, Index]).
request_spec(list_changed_files, Args, get, Path, none) :-
    !,
    get_dict(owner, Args, Owner),
    get_dict(repo, Args, Repo),
    get_dict(index, Args, Index),
    format(atom(Path), 'repos/~w/~w/pulls/~w/files', [Owner, Repo, Index]).
request_spec(get_comment_thread, Args, get, Path, none) :-
    !,
    get_dict(owner, Args, Owner),
    get_dict(repo, Args, Repo),
    get_dict(index, Args, Index),
    format(atom(Path), 'repos/~w/~w/issues/~w/comments', [Owner, Repo, Index]).
request_spec(post_issue_comment, Args, post, Path, Body) :-
    !,
    get_dict(owner, Args, Owner),
    get_dict(repo, Args, Repo),
    get_dict(index, Args, Index),
    format(atom(Path), 'repos/~w/~w/issues/~w/comments', [Owner, Repo, Index]),
    get_dict(body, Args, Text),
    Body = _{body:Text}.
request_spec(post_pr_review, Args, post, Path, Body) :-
    !,
    get_dict(owner, Args, Owner),
    get_dict(repo, Args, Repo),
    get_dict(index, Args, Index),
    format(atom(Path), 'repos/~w/~w/pulls/~w/reviews', [Owner, Repo, Index]),
    get_dict(event, Args, Event),
    get_dict(body, Args, Text),
    review_event(Event, ApiEvent),
    (   get_dict(comments, Args, Comments)
    ->  Body = _{body:Text, event:ApiEvent, comments:Comments}
    ;   Body = _{body:Text, event:ApiEvent}
    ).
request_spec(create_branch, Args, post, Path, Body) :-
    !,
    get_dict(owner, Args, Owner),
    get_dict(repo, Args, Repo),
    format(atom(Path), 'repos/~w/~w/branches', [Owner, Repo]),
    get_dict(new_branch, Args, NewBranch),
    get_dict(base_branch, Args, BaseBranch),
    Body = _{new_branch_name:NewBranch, old_branch_name:BaseBranch}.
request_spec(push_commit, Args, Method, Path, Body) :-
    !,
    get_dict(owner, Args, Owner),
    get_dict(repo, Args, Repo),
    get_dict(path, Args, FilePath),
    format(atom(Path), 'repos/~w/~w/contents/~w', [Owner, Repo, FilePath]),
    get_dict(branch, Args, Branch),
    get_dict(content_b64, Args, ContentB64),
    get_dict(message, Args, Message),
    (   get_dict(sha, Args, Sha)
    ->  Method = put,
        Body = _{branch:Branch, content:ContentB64, message:Message, sha:Sha}
    ;   Method = post,
        Body = _{branch:Branch, content:ContentB64, message:Message}
    ).
request_spec(create_pr, Args, post, Path, Body) :-
    !,
    get_dict(owner, Args, Owner),
    get_dict(repo, Args, Repo),
    format(atom(Path), 'repos/~w/~w/pulls', [Owner, Repo]),
    get_dict(title, Args, Title),
    get_dict(head, Args, Head),
    get_dict(base, Args, Base),
    (   get_dict(body, Args, PrBody)
    ->  Body = _{title:Title, head:Head, base:Base, body:PrBody}
    ;   Body = _{title:Title, head:Head, base:Base}
    ).

review_event(approve, 'APPROVED').
review_event(request_changes, 'REQUEST_CHANGES').
review_event(comment, 'COMMENT').

% -- host-side helpers (not model tools) --------------------------------------

%% get_file_content(+Owner, +Repo, +Branch, +Path, -Text) is semidet.
% Trusted host read via the contents API (used for .copilot at the base
% branch HEAD). Fails when the file does not exist or the API is
% unconfigured. Never registered as a model tool.
get_file_content(Owner, Repo, Branch, Path, Text) :-
    forgejo_config(Config),
    format(atom(EncodedPath), '~w', [Path]),
    uri_encoded(path, EncodedPath, Encoded2),
    format(atom(P), 'repos/~w/~w/contents/~w', [Owner, Repo, Encoded2]),
    format(atom(Q), '~w?ref=~w', [P, Branch]),
    build_url(Config.base, Q, Url),
    auth_option(Config.token, AuthOption),
    http_open(Url, Stream, [method(get), AuthOption]),
    set_stream(Stream, encoding(utf8)),
    catch(json_read_dict(Stream, Json), _, Json = none),
    close(Stream),
    Json \== none,
    get_dict(content, Json, B64),
    strip_base64_whitespace(B64, Clean),
    atom_codes(Clean, B64Codes),
    base64_decoded(B64Codes, TextCodes, []),
    atom_codes(Text, TextCodes).

strip_base64_whitespace(B64, Clean) :-
    atom_codes(B64, Codes),
    exclude(whitespace_code, Codes, CleanCodes),
    atom_codes(Clean, CleanCodes).

whitespace_code(C) :- memberchk(C, [10, 13, 32, 9]).

% -- handler ------------------------------------------------------------------

handler(Name, Args, Value) :-
    forgejo_config(Config),
    !,
    request_spec(Name, Args, Method, Path, Body),
    build_url(Config.base, Path, Url),
    auth_option(Config.token, AuthOption),
    (   Body == none
    ->  Options = [AuthOption]
    ;   atom_json_dict(BodyAtom, Body, []),
        Options = [AuthOption,
                   content_type('application/json'),
                   post(BodyAtom)]
    ),
    method_option(Method, MethodOption),
    http_open(Url, Stream, [MethodOption | Options]),
    set_stream(Stream, encoding(utf8)),
    (   Name == get_diff
    ->  read_stream_text(Stream, Value0),
        close(Stream)
    ;   catch(json_read_dict(Stream, Value0), _, Value0 = none),
        close(Stream)
    ),
    postprocess(Name, Value0, Value).
handler(_Name, _Args, _Value) :-
    throw(forgejo_config_error(
              "FORGEJO_URL and FORGEJO_TOKEN must be set in the environment")).

auth_option(Token, request_header('Authorization'=Auth)) :-
    format(atom(Auth), 'token ~w', [Token]).

method_option(get, method(get)).
method_option(post, method(post)).
method_option(put, method(put)).

read_stream_text(Stream, Text) :-
    get_code(Stream, C0),
    read_rest(Stream, C0, Codes),
    atom_codes(Text, Codes).

read_rest(_Stream, -1, []) :- !.
read_rest(Stream, C, [C | Rest]) :-
    get_code(Stream, C2),
    read_rest(Stream, C2, Rest).

postprocess(get_diff, Text, _{diff:Text}) :- !.
postprocess(list_issues_updated_since, Json, _{issues:Json}) :- !.
postprocess(list_changed_files, Json, _{files:Json}) :- !.
postprocess(get_comment_thread, Json, _{comments:Json}) :- !.
postprocess(get_issue, Json, _{issue:Json}) :- !.
postprocess(get_pr, Json, _{pull:Json}) :- !.
postprocess(create_branch, Json, _{branch:Json}) :- !.
postprocess(post_issue_comment, Json, _{comment_id:Json.id}) :- !.
postprocess(create_pr, Json, _{pr_index:Json.number}) :- !.
postprocess(post_pr_review, Json, _{review_id:Json.id, event:Json.event}) :- !.
postprocess(push_commit, Json, _{commit_sha:Json.commit.sha}) :- !.
postprocess(_Name, Json, Json).
