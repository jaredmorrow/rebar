%% -*- erlang-indent-level: 4;indent-tabs-mode: nil -*-
%% ex: ts=4 sw=4 et
%% -------------------------------------------------------------------
%%
%% rebar: Erlang Build Tools
%%
%% Copyright (c) 2011 Joe Williams (joe@joetify.com)
%%
%% Permission is hereby granted, free of charge, to any person obtaining a copy
%% of this software and associated documentation files (the "Software"), to deal
%% in the Software without restriction, including without limitation the rights
%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%% copies of the Software, and to permit persons to whom the Software is
%% furnished to do so, subject to the following conditions:
%%
%% The above copyright notice and this permission notice shall be included in
%% all copies or substantial portions of the Software.
%%
%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
%% THE SOFTWARE.
%% -------------------------------------------------------------------

-module(rebar_upgrade).

-include("rebar.hrl").
-include_lib("kernel/include/file.hrl").

-export(['generate-upgrade'/2]).

%% ====================================================================
%% Public API
%% ====================================================================

'generate-upgrade'(_Config, ReltoolFile) ->
    %% Get the old release path
    OldVerPath = rebar_rel_utils:get_previous_release_path(),

    %% Run checks to make sure that building a package is possible
    {NewName, NewVer} = run_checks(OldVerPath, ReltoolFile),
    NameVer = NewName ++ "_" ++ NewVer,

    %% Save the code path prior to doing anything
    OrigPath = code:get_path(),

    %% Prepare the environment for building the package
    ok = setup(OldVerPath, NewName, NewVer, NameVer),

    %% Build the package
    run_systools(NameVer, NewName),

    %% Boot file changes
    {ok, _} = boot_files(NewVer, NewName),

    %% Extract upgrade and tar it back up with changes
    make_tar(NameVer),

    %% Clean up files that systools created
    ok = cleanup(NameVer, NewName, NewVer),

    %% Restore original path
    true = code:set_path(OrigPath),

    ok.

%% ===================================================================
%% Internal functions
%% ==================================================================

run_checks(OldVerPath, ReltoolFile) ->
    true = rebar_utils:prop_check(filelib:is_dir(OldVerPath),
                      "Release directory doesn't exist (~p)~n", [OldVerPath]),

    {Name, Ver} = rebar_rel_utils:get_reltool_release_info(ReltoolFile),

    NamePath = filename:join([".", Name]),
    true = rebar_utils:prop_check(filelib:is_dir(NamePath),
                      "Release directory doesn't exist (~p)~n", [NamePath]),

    {NewName, NewVer} = NewNameAndVer =
        rebar_rel_utils:get_rel_release_info(Name, NamePath),
    {OldName, OldVer} = rebar_rel_utils:get_rel_release_info(Name, OldVerPath),

    true = rebar_utils:prop_check(NewName == OldName,
                      "New and old .rel release names do not match~n", []),
    true = rebar_utils:prop_check(Name == NewName,
                      "Reltool and .rel release names do not match~n", []),
    true = rebar_utils:prop_check(NewVer =/= OldVer,
                      "New and old .rel contain the same version~n", []),
    true = rebar_utils:prop_check(Ver == NewVer,
                      "Reltool and .rel versions do not match~n", []),

    NewNameAndVer.

setup(OldVerPath, NewName, NewVer, NameVer) ->
    NewRelPath = filename:join([".", NewName]),
    Src = filename:join([NewRelPath, "releases",
                         NewVer, NewName ++ ".rel"]),
    Dst = filename:join([".", NameVer ++ ".rel"]),
    {ok, _} = file:copy(Src, Dst),
    ok = code:add_pathsa(
           lists:append([
                         filelib:wildcard(filename:join([OldVerPath,
                                                         "releases", "*"])),
                         filelib:wildcard(filename:join([OldVerPath,
                                                         "lib", "*", "ebin"])),
                         filelib:wildcard(filename:join([NewRelPath,
                                                         "lib", "*", "ebin"])),
                         filelib:wildcard(filename:join([NewRelPath, "*"]))
                        ])).

run_systools(NewVer, Name) ->
    Opts = [silent],
    NameList = [Name],
    case systools:make_relup(NewVer, NameList, NameList, Opts) of
        {error, _, _Message} ->
            ?ABORT("Systools aborted with: ~p~n", [_Message]);
        _ ->
            ?DEBUG("Relup created~n", []),
            case systools:make_script(NewVer, Opts) of
                {error, _, _Message1} ->
                    ?ABORT("Systools aborted with: ~p~n", [_Message1]);
                _ ->
                    ?DEBUG("Script created~n", []),
                    case systools:make_tar(NewVer, Opts) of
                        {error, _, _Message2} ->
                            ?ABORT("Systools aborted with: ~p~n", [_Message2]);
                        _ ->
                            ok
                    end
            end
    end.

boot_files(Ver, Name) ->
    ok = file:make_dir(filename:join([".", "releases"])),
    ok = file:make_dir(filename:join([".", "releases", Ver])),
    ok = file:make_symlink(
           filename:join(["start.boot"]),
           filename:join([".", "releases", Ver, Name ++ ".boot"])),
    {ok, _} = file:copy(
                filename:join([".", Name, "releases", Ver, "start_clean.boot"]),
                filename:join([".", "releases", Ver, "start_clean.boot"])).

make_tar(NameVer) ->
    Filename = NameVer ++ ".tar.gz",
    ok = erl_tar:extract(Filename, [compressed]),
    ok = file:delete(Filename),
    {ok, Tar} = erl_tar:open(Filename, [write, compressed]),
    ok = erl_tar:add(Tar, "lib", []),
    ok = erl_tar:add(Tar, "releases", []),
    ok = erl_tar:close(Tar),
    ?CONSOLE("~s upgrade package created~n", [NameVer]).

cleanup(NameVer, Name, Ver) ->
    ?DEBUG("Removing files needed for building the upgrade~n", []),
    Files = [
             filename:join([".", "releases", Ver, Name ++ ".boot"]),
             filename:join([".", NameVer ++ ".rel"]),
             filename:join([".", NameVer ++ ".boot"]),
             filename:join([".", NameVer ++ ".script"]),
             filename:join([".", "relup"])
            ],
    lists:foreach(fun(F) -> ok = file:delete(F) end, Files),

    ok = remove_dir_tree("releases"),
    ok = remove_dir_tree("lib").

%% taken from http://www.erlang.org/doc/system_principles/create_target.html
remove_dir_tree(Dir) ->
    remove_all_files(".", [Dir]).
remove_all_files(Dir, Files) ->
    lists:foreach(fun(File) ->
                          FilePath = filename:join([Dir, File]),
                          {ok, FileInfo} = file:read_file_info(FilePath),
                          case FileInfo#file_info.type of
                              directory ->
                                  {ok, DirFiles} = file:list_dir(FilePath),
                                  remove_all_files(FilePath, DirFiles),
                                  file:del_dir(FilePath);
                              _ ->
                                  file:delete(FilePath)
                          end
                  end, Files).
