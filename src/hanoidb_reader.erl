%% ----------------------------------------------------------------------------
%%
%% hanoidb: LSM-trees (Log-Structured Merge Trees) Indexed Storage
%%
%% Copyright 2011-2012 (c) Trifork A/S.  All Rights Reserved.
%% http://trifork.com/ info@trifork.com
%%
%% Copyright 2012 (c) Basho Technologies, Inc.  All Rights Reserved.
%% http://basho.com/ info@basho.com
%%
%% This file is provided to you under the Apache License, Version 2.0 (the
%% "License"); you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
%% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.  See the
%% License for the specific language governing permissions and limitations
%% under the License.
%%
%% ----------------------------------------------------------------------------

-module(hanoidb_reader).
-author('Kresten Krab Thorup <krab@trifork.com>').

-include_lib("kernel/include/file.hrl").
-include("include/hanoidb.hrl").
-include("hanoidb.hrl").
-include("include/plain_rpc.hrl").

-define(ASSERT_WHEN(X), when X).

-export([open/1, open/2,close/1,lookup/2,fold/3,range_fold/4, destroy/1]).
-export([first_node/1,next_node/1]).
-export([serialize/1, deserialize/1]).

-record(node, {level       :: non_neg_integer(),
               members=[]  :: list(any()) | binary() }).

-record(index, {file       :: file:io_device(),
                root= none :: #node{} | none,
                bloom      :: term(),
                name       :: string(),
                config=[]  :: term() }).

-type read_file() :: #index{}.
-export_type([read_file/0]).

-spec open(Name::string()) -> {ok, read_file()} | {error, any()}.
open(Name) ->
    open(Name, [random]).

-type config() :: [sequential | folding | random | {atom(), term()}].
-spec open(Name::string(), config()) -> {ok, read_file()}  | {error, any()}.
open(Name, Config) ->
    case proplists:get_bool(sequential, Config) of
        true ->
            ReadBufferSize = hanoidb:get_opt(read_buffer_size, Config, 512 * 1024),
            case file:open(Name, [raw,read,{read_ahead, ReadBufferSize},binary]) of
                {ok, File} ->
                    {ok, #index{file=File, name=Name, config=Config}};
                {error, _}=Err ->
                    Err
            end;

        false ->
            {ok, File} =
                case proplists:get_bool(folding, Config) of
                    true ->
                        ReadBufferSize = hanoidb:get_opt(read_buffer_size, Config, 512 * 1024),
                        file:open(Name, [read, {read_ahead, ReadBufferSize}, binary]);
                    false ->
                        file:open(Name, [read, binary])
                end,

            {ok, FileInfo} = file:read_file_info(Name),

            %% read and validate magic tag
            {ok, ?FILE_FORMAT} = file:pread(File, 0, byte_size(?FILE_FORMAT)),

            %% read root position
            {ok, <<RootPos:64/unsigned>>} = file:pread(File, FileInfo#file_info.size - 8, 8),
            {ok, <<BloomSize:32/unsigned>>} = file:pread(File, FileInfo#file_info.size - 12, 4),
            {ok, BloomData} = file:pread(File, (FileInfo#file_info.size - 12 - BloomSize), BloomSize),
            {ok, Bloom} = hanoidb_util:bin_to_bloom(BloomData),

            %% read in the root node
            Root =
                case read_node(File, RootPos) of
                    {ok, Node} ->
                        Node;
                    eof ->
                        none
                end,

            {ok, #index{file=File, root=Root, bloom=Bloom, name=Name, config=Config}}
    end.

destroy(#index{file=File, name=Name}) ->
    ok = file:close(File),
    file:delete(Name).

serialize(#index{file=File, bloom=undefined }=Index) ->
    {ok, Position} = file:position(File, cur),
    ok = file:close(File),
    {seq_read_file, Index, Position}.

deserialize({seq_read_file, Index, Position}) ->
    {ok, #index{file=File}=Index2} = open(Index#index.name, Index#index.config),
    {ok, Position} = file:position(File, {bof, Position}),
    Index2.




fold(Fun, Acc0, #index{file=File}) ->
    {ok, Node} = read_node(File,?FIRST_BLOCK_POS),
    fold0(File,fun({K,V},Acc) -> Fun(K,V,Acc) end,Node,Acc0).

fold0(File,Fun,#node{level=0, members=BinPage},Acc0) when is_binary(BinPage) ->
    Acc1 = vbisect:foldl(fun(K, V, Acc2) -> Fun({K, decode_binary_value(V)}, Acc2) end,Acc0,BinPage),
    fold1(File,Fun,Acc1);
fold0(File,Fun,#node{level=0, members=List},Acc0) when is_list(List) ->
    Acc1 = lists:foldl(Fun,Acc0,List),
    fold1(File,Fun,Acc1);
fold0(File,Fun,_InnerNode,Acc0) ->
    fold1(File,Fun,Acc0).

fold1(File,Fun,Acc0) ->
    case next_leaf_node(File) of
        eof ->
            Acc0;
        {ok, Node} ->
            fold0(File,Fun,Node,Acc0)
    end.

-spec range_fold(fun((binary(),binary(),any()) -> any()), any(), #index{}, #key_range{}) ->
                        {limit, any(), binary()} | {done, any()}.
range_fold(Fun, Acc0, #index{file=File,root=Root}, Range) ->
    case Range#key_range.from_key =< first_key(Root) of
        true ->
            {ok, _} = file:position(File, ?FIRST_BLOCK_POS),
            range_fold_from_here(Fun, Acc0, File, Range, Range#key_range.limit);
        false ->
            case find_leaf_node(File,Range#key_range.from_key,Root,?FIRST_BLOCK_POS) of
                {ok, {Pos,_}} ->
                    {ok, _} = file:position(File, Pos),
                    range_fold_from_here(Fun, Acc0, File, Range, Range#key_range.limit);
                {ok, Pos} ->
                    {ok, _} = file:position(File, Pos),
                    range_fold_from_here(Fun, Acc0, File, Range, Range#key_range.limit);
                none ->
                    {done, Acc0}
            end
    end.

first_key(#node{members=Dict}) ->
    {_,FirstKey} = fold_until_stop(fun({K,_},_) -> {stop, K} end, none, Dict),
    FirstKey.

fold_until_stop(Fun,Acc,List) when is_list(List) ->
    fold_until_stop2(Fun, {continue, Acc}, List);
fold_until_stop(Fun,Acc0,Bin) when is_binary(Bin) ->
    vbisect:fold_until_stop(fun({Key,VBin},Acc1) ->
%                                    io:format("-> DOING ~p,~p~n", [Key,Acc1]),
                                    Fun({Key, decode_binary_value(VBin)}, Acc1)
                            end,
                            Acc0,
                            Bin).

fold_until_stop2(_Fun,{stop,Result},_) ->
    {stopped, Result};
fold_until_stop2(_Fun,{continue, Acc},[]) ->
    {ok, Acc};
fold_until_stop2(Fun,{continue, Acc},[H|T]) ->
    fold_until_stop2(Fun,Fun(H,Acc),T).

% TODO this is duplicate code also found in hanoidb_nursery
is_expired(?TOMBSTONE) ->
    false;
is_expired({_Value, TStamp}) ->
    hanoidb_util:has_expired(TStamp);
is_expired(Bin) when is_binary(Bin) ->
    false.

get_value({Value, _TStamp}) ->
    Value;
get_value(Value) ->
    Value.

range_fold_from_here(Fun, Acc0, File, Range, undefined) ->
%    io:format("RANGE_FOLD_FROM_HERE(~p,~p)~n", [Acc0,File]),
    case next_leaf_node(File) of
        eof ->
            {done, Acc0};

        {ok, #node{members=Members}} ->
            case fold_until_stop(fun({Key,_}, Acc) when not ?KEY_IN_TO_RANGE(Key,Range) ->
                                         {stop, {done, Acc}};
                                    ({Key,Value}, Acc) when ?KEY_IN_FROM_RANGE(Key, Range) ->
                                         case is_expired(Value) of
                                             true ->
                                                 {continue, Acc};
                                             false ->
                                                 {continue, Fun(Key, get_value(Value), Acc)}
                                         end;
                                    (_Huh, Acc) ->
%                                         io:format("SKIPPING ~p~n", [_Huh]),
                                         {continue, Acc}
                                 end,
                                 Acc0,
                                 Members) of
                {stopped, Result} -> Result;
                {ok, Acc1} ->
                    range_fold_from_here(Fun, Acc1, File, Range, undefined)
            end
    end;

range_fold_from_here(Fun, Acc0, File, Range, N0) ->
    case next_leaf_node(File) of
        eof ->
            {done, Acc0};

        {ok, #node{members=Members}} ->
            case fold_until_stop(fun({Key,_}, {0,Acc}) ->
                                         {stop, {limit, Acc, Key}};
                                    ({Key,_}, {_,Acc}) when not ?KEY_IN_TO_RANGE(Key,Range)->
                                         {stop, {done, Acc}};
                                    ({Key,?TOMBSTONE}, {N1,Acc}) when ?KEY_IN_FROM_RANGE(Key,Range) ->
                                         {continue, {N1, Fun(Key, ?TOMBSTONE, Acc)}};
                                    ({Key,{?TOMBSTONE,TStamp}}, {N1,Acc}) when ?KEY_IN_FROM_RANGE(Key,Range) ->
                                         case hanoidb_util:has_expired(TStamp) of
                                             true ->
                                                 {continue, {N1,Acc}};
                                             false ->
                                                 {continue, {N1, Fun(Key, ?TOMBSTONE, Acc)}}
                                         end;
                                    ({Key,Value}, {N1,Acc}) when ?KEY_IN_FROM_RANGE(Key,Range) ->
                                         case is_expired(Value) of
                                             true ->
                                                 {continue, {N1,Acc}};
                                             false ->
                                                 {continue, {N1-1, Fun(Key, get_value(Value), Acc)}}
                                         end;
                                    (_, Acc) ->
                                         {continue, Acc}
                                 end,
                                 {N0, Acc0},
                                 Members)
             of
                {stopped, Result} ->
                    Result;
                {ok, {N2, Acc1}} ->
                    range_fold_from_here(Fun, Acc1, File, Range, N2)
            end
    end.

find_leaf_node(_File,_FromKey,#node{level=0},Pos) ->
    {ok, Pos};
find_leaf_node(File,FromKey,#node{members=Members,level=N},_) when is_list(Members) ->
    case find_start(FromKey, Members) of
        {ok, ChildPos} ->
            recursive_find(File, FromKey, N, ChildPos);
        not_found ->
            none
    end;
find_leaf_node(File,FromKey,#node{members=Members,level=N},_) when is_binary(Members) ->
    case vbisect:find_geq(FromKey,Members) of
        {ok, _, <<?TAG_POSLEN32, Pos:64/unsigned, Len:32/unsigned>>} ->
%            io:format("** FIND_LEAF_NODE(~p,~p) -> {~p,~p}~n", [FromKey, N, Pos,Len]),
            recursive_find(File, FromKey, N, {Pos,Len});
        none ->
%            io:format("** FIND_LEAF_NODE(~p,~p) -> none~n", [FromKey, N]),
            none
    end;
find_leaf_node(_,_,none,_) ->
    none.

recursive_find(_File,_FromKey,1,ChildPos) ->
    {ok, ChildPos};
recursive_find(File,FromKey,N,ChildPos) when N>1 ->
    case read_node(File,ChildPos) of
        {ok, ChildNode} ->
            find_leaf_node(File, FromKey,ChildNode,ChildPos);
        eof ->
            none
    end.


%% used by the merger, needs list value
first_node(#index{file=File}) ->
    case read_node(File, ?FIRST_BLOCK_POS) of
        {ok, #node{level=0, members=Members}} ->
            {kvlist, decode_member_list(Members)};
        eof->
            none
    end.

%% used by the merger, needs list value
next_node(#index{file=File}=_Index) ->
    case next_leaf_node(File) of
        {ok, #node{level=0, members=Members}} ->
            {kvlist, decode_member_list(Members)};
        eof ->
            end_of_data
    end.

decode_member_list(List) when is_list(List) ->
    List;
decode_member_list(BinDict) when is_binary(BinDict) ->
    vbisect:foldr( fun(Key,Value,Acc) ->
                           [{Key, decode_binary_value(Value) }|Acc]
                   end,
                   [],
                   BinDict).

close(#index{file=undefined}) ->
    ok;
close(#index{file=File}) ->
    file:close(File).


lookup(#index{file=File, root=Node, bloom=Bloom}, Key) ->
    case ?BLOOM_CONTAINS(Bloom, Key) of
        true ->
            case lookup_in_node(File, Node, Key) of
                not_found ->
                    not_found;
                {ok, {Value, TStamp}} ?ASSERT_WHEN(Value =:= ?TOMBSTONE; is_binary(Value))  ->
                    case hanoidb_util:has_expired(TStamp) of
                        true -> not_found;
                        false -> {ok, Value}
                    end;
                {ok, Value}=Reply ?ASSERT_WHEN(Value =:= ?TOMBSTONE; is_binary(Value)) ->
                    Reply
            end;
        false ->
            not_found
    end.

lookup_in_node(_File,#node{level=0,members=Members}, Key) ->
    find_in_leaf(Key,Members);

lookup_in_node(File,#node{members=Members},Key) when is_binary(Members) ->
    case vbisect:find_geq(Key,Members) of
        {ok, _Key, <<?TAG_POSLEN32, Pos:64, Size:32>>} ->
%            io:format("FOUND ~p @ ~p~n", [_Key, {Pos,Size}]),
            case read_node(File,{Pos,Size}) of
                {ok, Node} ->
                    lookup_in_node(File, Node, Key);
                eof ->
                    not_found
            end;
        none ->
            not_found
    end;

lookup_in_node(File,#node{members=Members},Key) ->
    case find_1(Key, Members) of
        {ok, {Pos,Size}} ->
            %% do this in separate process, to avoid having to
            %% garbage collect all the inner node junk
            PID = proc_lib:spawn_link(fun() ->
                                              receive
                                                  ?CALL(From,read) ->
                                                      case read_node(File, {Pos,Size}) of
                                                          {ok, Node} ->
                                                              Result = lookup_in_node2(File, Node, Key),
                                                              plain_rpc:send_reply(From, Result);
                                                          eof ->
                                                              plain_rpc:send_reply(From, {error, eof})
                                                      end
                                              end
                                      end),
            try plain_rpc:call(PID, read)
            catch
                Class:Ex:Stacktrace ->
                    error_logger:error_msg("crashX: ~p:~p ~p~n", [Class,Ex,Stacktrace]),
                    not_found
            end;

        not_found ->
            not_found
    end.


lookup_in_node2(_File,#node{level=0,members=Members},Key) ->
    case lists:keyfind(Key,1,Members) of
        false ->
            not_found;
        {_,Value} ->
            {ok, Value}
    end;

lookup_in_node2(File,#node{members=Members},Key) ->
    case find_1(Key, Members) of
        {ok, {Pos,Size}} ->
            case read_node(File, {Pos,Size}) of
                {ok, Node} ->
                    lookup_in_node2(File, Node, Key);
                eof ->
                    {error, eof}
            end;
        not_found ->
            not_found
    end.


find_1(K, [{K1,V},{K2,_}|_]) when K >= K1, K < K2 ->
    {ok, V};
find_1(K, [{K1,V}]) when K >= K1 ->
    {ok, V};
find_1(K, [_|T]) ->
    find_1(K,T);
find_1(_, _) ->
    not_found.


find_start(K, [{_,V},{K2,_}|_]) when K < K2 ->
    {ok, V};
find_start(_, [{_,{_,_}=V}]) ->
    {ok, V};
find_start(K, KVs) ->
    find_1(K, KVs).


-spec read_node(file:io_device(), non_neg_integer() | { non_neg_integer(), non_neg_integer() }) ->
                       {ok, #node{}} | eof.

read_node(File, {Pos, Size}) ->
%    error_logger:info_msg("read_node ~p ~p ~p~n", [File, Pos, Size]),
    {ok, <<_:32/unsigned, Level:16/unsigned, Data/binary>>} = file:pread(File, Pos, Size),
    hanoidb_util:decode_index_node(Level, Data);

read_node(File, Pos) ->
%    error_logger:info_msg("read_node ~p ~p~n", [File, Pos]),
    {ok, Pos} = file:position(File, Pos),
    Result = read_node(File),
%    error_logger:info_msg("decoded ~p ~p~n", [Pos, Result]),
    Result.

read_node(File) ->
%    error_logger:info_msg("read_node ~p~n", [File]),
    {ok, <<Len:32/unsigned, Level:16/unsigned>>} = file:read(File, 6),
%    error_logger:info_msg("decoded ~p ~p~n", [Len, Level]),
    case Len of
        0 ->
            eof;
        _ ->
            {ok, Data} = file:read(File, Len-2),
            hanoidb_util:decode_index_node(Level, Data)
    end.


next_leaf_node(File) ->
    case file:read(File, 6) of
        eof ->
            %% premature end-of-file
            eof;
        {ok, <<0:32/unsigned, _:16/unsigned>>} ->
            eof;
        {ok, <<Len:32/unsigned, 0:16/unsigned>>} ->
            {ok, Data} = file:read(File, Len-2),
            hanoidb_util:decode_index_node(0, Data);
        {ok, <<Len:32/unsigned, _:16/unsigned>>} ->
            {ok, _} = file:position(File, {cur,Len-2}),
            next_leaf_node(File)
    end.


find_in_leaf(Key,Bin) when is_binary(Bin) ->
    case vbisect:find(Key,Bin) of
        {ok, BinValue} ->
            {ok, decode_binary_value(BinValue)};
        error ->
            not_found
    end;
find_in_leaf(Key,List) when is_list(List) ->
    case lists:keyfind(Key, 1, List) of
        {_, Value} ->
            {ok, Value};
        false ->
            not_found
    end.

decode_binary_value(<<?TAG_KV_DATA, Value/binary>>) ->
    Value;
decode_binary_value(<<?TAG_KV_DATA2, TStamp:32, Value/binary>>) ->
    {Value, TStamp};
decode_binary_value(<<?TAG_DELETED>>) ->
    ?TOMBSTONE;
decode_binary_value(<<?TAG_DELETED2, TStamp:32>>) ->
    {?TOMBSTONE, TStamp};
decode_binary_value(<<?TAG_POSLEN32, Pos:64, Len:32>>) ->
    {Pos, Len}.
