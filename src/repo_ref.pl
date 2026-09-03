:- module(repo_ref,
          [ split_repo/3
          ]).

/** <module> Repository reference

`Owner/Name` is the closed repository reference used across the service,
the delegate, and the daemon. One shared parser so the vocabulary cannot
drift between call sites.
*/

%% split_repo(+Repo, -Owner, -Name) is semidet.
split_repo(Repo, Owner, Name) :-
    atom_codes(Repo, Codes),
    append(OwnerCodes, [0'/ | NameCodes], Codes),
    !,
    atom_codes(Owner, OwnerCodes),
    atom_codes(Name, NameCodes).
