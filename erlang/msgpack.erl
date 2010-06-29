%%
%% MessagePack for Erlang
%%
%% Copyright (C) 2009-2010 UENISHI Kota
%%
%%    Licensed under the Apache License, Version 2.0 (the "License");
%%    you may not use this file except in compliance with the License.
%%    You may obtain a copy of the License at
%%
%%        http://www.apache.org/licenses/LICENSE-2.0
%%
%%    Unless required by applicable law or agreed to in writing, software
%%    distributed under the License is distributed on an "AS IS" BASIS,
%%    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%    See the License for the specific language governing permissions and
%%    limitations under the License.

-module(msgpack).
-author('kuenishi+msgpack@gmail.com').

%% tuples, atoms are not supported. lists, integers, double, and so on.
%% see http://msgpack.sourceforge.jp/spec for
%% supported formats. APIs are almost compatible
%% for C API (http://msgpack.sourceforge.jp/c:doc)
%% except buffering functions (both copying and zero-copying).
-export([pack/1, unpack/1, unpack_all/1]).

% compile:
% erl> c(msgpack).
% erl> S = <some term>.
% erl> {S, <<>>} = msgpack:unpack( msgpack:pack(S) ).
-type reason() ::  enomem | {badarg, term()}.
-type msgpack_term() :: [msgpack_term()] | {[{msgpack_term(),msgpack_term()}]} | integer() | float() | binary().

% ===== external APIs ===== %

% @doc Pack one erlang term into an msgpack message.
-spec pack(Term::msgpack_term()) -> binary() | reason().
pack(O) when is_integer(O) andalso O < 0 ->
    pack_int_(O);
pack(O) when is_integer(O) ->
    pack_uint_(O);
pack(O) when is_float(O) ->
    pack_double(O);
pack(nil) ->
    pack_nil();
pack(true) ->
    pack_true();
pack(false) ->
    pack_false();
pack(Bin) when is_binary(Bin) ->
    pack_raw(Bin);
pack(List)  when is_list(List) ->
    pack_array(List);
pack({Map}) when is_list(Map) ->
    pack_map(Map);
pack(Map) when is_tuple(Map), element(1,Map)=:=dict ->
    pack_map(dict:from_list(Map));
pack(Other) ->
    {error, {badarg, Other}}.

% @doc Unpack one (possibly deeply nested) msgpack message into an erlang term.
%      If failed in decoding and not end, get more data
%      and feed more Bin into this function.
-spec unpack( binary() ) -> {Decoded::msgpack_term(), Rest::binary()} | {more, undefined} | {error, reason()}.
unpack(Bin) when is_binary(Bin) ->
    unpack_(Bin);
unpack(Other) ->
    {error, {badarg, Other}}.

-spec unpack_all( binary() ) -> [msgpack_term()].
unpack_all(Data)->
    case unpack(Data) of
	{ Term, Binary } when bit_size(Binary) =:= 0 ->
	    [Term];
	{ Term, Binary } when is_binary(Binary) ->
	    [Term|unpack_all(Binary)]
    end.


% ===== internal APIs ===== %

% positive fixnum
pack_uint_(N) when N < 128 ->
    << 2#0:1, N:7 >>;
% uint 8
pack_uint_(N) when N < 256 ->
    << 16#CC:8, N:8 >>;
% uint 16
pack_uint_(N) when N < 65536 ->
    << 16#CD:8, N:16/big-unsigned-integer-unit:1 >>;
% uint 32
pack_uint_(N) when N < 16#FFFFFFFF->
    << 16#CE:8, N:32/big-unsigned-integer-unit:1 >>;
% uint 64
pack_uint_(N) ->
    << 16#CF:8, N:64/big-unsigned-integer-unit:1 >>.

% negative fixnum
pack_int_(N) when N >= -32->
    << 2#111:3, N:5 >>;
% int 8
pack_int_(N) when N >= -256 ->
    << 16#D0:8, N:8 >>;
% int 16
pack_int_(N) when N >= -65536 ->
    << 16#D1:8, N:16/big-signed-integer-unit:1 >>;
% int 32
pack_int_(N) when N >= -16#FFFFFFFF ->
    << 16#D2:8, N:32/big-signed-integer-unit:1 >>;
% int 64
pack_int_(N) ->
    << 16#D3:8, N:64/big-signed-integer-unit:1 >>.

% nil/true/false
pack_nil() ->  << 16#C0:8 >>.
pack_true()->  << 16#C3:8 >>.
pack_false()-> << 16#C2:8 >>.

% float : erlang's float is always IEEE 754 64bit format.
%pack_float(F) when is_float(F)->
%    << 16#CA:8, F:32/big-float-unit:1 >>.
%    pack_double(F).
% double
pack_double(F) ->
    << 16#CB:8, F:64/big-float-unit:1 >>.

% raw bytes
pack_raw(Bin) ->
    case byte_size(Bin) of
	Len when Len < 6->
	    << 2#101:3, Len:5, Bin/binary >>;
	Len when Len < 16#10000 -> % 65536
	    << 16#DA:8, Len:16/big-unsigned-integer-unit:1, Bin/binary >>;
	Len ->
	    << 16#DB:8, Len:32/big-unsigned-integer-unit:1, Bin/binary >>
    end.

% list
pack_array(L) ->
    case length(L) of
 	Len when Len < 16 ->
 	    << 2#1001:4, Len:4/integer-unit:1, (pack_array_(L, <<>>))/binary >>;
	Len when Len < 16#10000 -> % 65536
	    << 16#DC:8, Len:16/big-unsigned-integer-unit:1, (pack_array_(L, <<>>))/binary >>;
	Len ->
	    << 16#DD:8, Len:32/big-unsigned-integer-unit:1, (pack_array_(L, <<>>))/binary >>
    end.
pack_array_([], Acc) -> Acc;
pack_array_([Head|Tail], Acc) ->
    pack_array_(Tail, <<Acc/binary,  (pack(Head))/binary>>).

% FIXME! this should be tail-recursive and without lists:reverse/1
unpack_array_(Remain, 0, RetList) -> {lists:reverse(RetList), Remain};
unpack_array_(Bin, RestLen, RetList) ->
    case unpack(Bin) of
	{more, undefined} -> {more, undefined};
	{Term, Rest}-> unpack_array_(Rest, RestLen-1, [Term|RetList])
    end.

% FIXME: write test for pack_map/1
pack_map(M)->
    case length(M) of
	Len when Len < 16 ->
 	    << 2#1000:4, Len:4/integer-unit:1, (pack_map_(M, <<>>))/binary >>;
	Len when Len < 16#10000 -> % 65536
	    << 16#DE:8, Len:16/big-unsigned-integer-unit:1, (pack_map_(M, <<>>))/binary >>;
	Len ->
	    << 16#DF:8, Len:32/big-unsigned-integer-unit:1, (pack_map_(M, <<>>))/binary >>
    end.

pack_map_([], Acc) -> Acc;
pack_map_([{Key,Value}|Tail], Acc) ->
    pack_map_(Tail, << Acc/binary, (pack(Key))/binary, (pack(Value))/binary>>).

% FIXME: write test for unpack_map/1
-spec unpack_map_(binary(), non_neg_integer(), [{msgpack_term(), msgpack_term()}]) -> {more, undefined} | {any(), binary()} | {error, reason()}.
unpack_map_(Bin,  0,  Acc) -> {{lists:reverse(Acc)}, Bin};
unpack_map_(Bin, Len, Acc) ->
    case unpack(Bin) of
	{more, undefined} -> {more, undefined};
	{Key, Rest} ->
	    case unpack(Rest) of
		{more, undefined} -> {more, undefined};
		{Value, Rest2} ->
		    unpack_map_(Rest2,Len-1,[{Key,Value}|Acc])
	    end
    end.


-spec unpack_(Payload::binary()) -> {more, undefined} | {msgpack_term(), binary()} | {error, reason()}.
% Atoms
unpack_(<<16#C0, Rest/binary>>) -> {nil, Rest};
unpack_(<<16#C2, Rest/binary>>) -> {false, Rest};
unpack_(<<16#C3, Rest/binary>>) -> {true, Rest};

% Floats
unpack_(<<16#CA, Val:32/float-unit:1, Rest/binary>>) -> {Val, Rest};
unpack_(<<16#CB, Val:64/float-unit:1, Rest/binary>>) -> {Val, Rest};

% Unsigned integers
unpack_(<<16#CC, Val:8/unsigned-integer, Rest/binary>>) ->             {Val, Rest};
unpack_(<<16#CD, Val:16/big-unsigned-integer-unit:1, Rest/binary>>) -> {Val, Rest};
unpack_(<<16#CE, Val:32/big-unsigned-integer-unit:1, Rest/binary>>) -> {Val, Rest};
unpack_(<<16#CF, Val:64/big-unsigned-integer-unit:1, Rest/binary>>) -> {Val, Rest};

% Signed integers
unpack_(<<16#D0, Val:8/signed-integer, Rest/binary>>) ->             {Val, Rest};
unpack_(<<16#D1, Val:16/big-signed-integer-unit:1, Rest/binary>>) -> {Val, Rest};
unpack_(<<16#D2, Val:32/big-signed-integer-unit:1, Rest/binary>>) -> {Val, Rest};
unpack_(<<16#D3, Val:64/big-signed-integer-unit:1, Rest/binary>>) -> {Val, Rest};

% Raw bytes
unpack_(<<16#DA, Len:16/unsigned-integer-unit:1, Val:Len/binary, Rest/binary>>) -> {Val, Rest};
unpack_(<<16#DB, Len:32/unsigned-integer-unit:1, Val:Len/binary, Rest/binary>>) -> {Val, Rest};

% Arrays
unpack_(<<16#DC, Len:16/big-unsigned-integer-unit:1, Rest/binary>>) -> unpack_array_(Rest, Len, []);
unpack_(<<16#DD, Len:32/big-unsigned-integer-unit:1, Rest/binary>>) -> unpack_array_(Rest, Len, []);

% Maps
unpack_(<<16#DE, Len:16/big-unsigned-integer-unit:1, Rest/binary>>) -> unpack_map_(Rest, Len, []);
unpack_(<<16#DF, Len:32/big-unsigned-integer-unit:1, Rest/binary>>) -> unpack_map_(Rest, Len, []);

% Tag-encoded lengths (kept last, for speed)
unpack_(<<0:1, Val:7, Rest/binary>>) ->                      {Val, Rest};                  % pos fixnum
unpack_(<<2#111:3, Val:5, Rest/binary>>) ->                  {Val - 2#100000, Rest};       % neg fixnum
unpack_(<<2#101:3, Len:5, Val:Len/binary, Rest/binary>>) ->  {Val, Rest};                  % fixraw
unpack_(<<2#1001:4, Len:4, Rest/binary>>) ->                 unpack_array_(Rest, Len, []); % fixarray
unpack_(<<2#1000:4, Len:4, Rest/binary>>) ->                 unpack_map_(Rest, Len, []);   % fixmap

% Incomplete / invalid data
unpack_(<<F:8, Rest/binary>>) when F==16#C1; F==16#C4; F==16#C5; F==16#C6; F==16#C7; F==16#C8; F==16#C9; F==16#D5; F==16#D6; F==16#D7; F==16#D8; F==16#D9->
    {error, {badarg, <<F, Rest/binary>>}};
unpack_(_Bin) ->
    {more, undefined}.


% ===== test codes ===== %
-include_lib("eunit/include/eunit.hrl").
-ifdef(EUNIT).

compare_all([], [])-> ok;
compare_all([], R)-> {toomuchrhs, R};
compare_all(L, [])-> {toomuchlhs, L};
compare_all([LH|LTL], [RH|RTL]) ->
    LH=RH,
    compare_all(LTL, RTL).

test_data()->
    [true, false, nil,
     0, 1, 2, 123, 512, 1230, 678908, 16#FFFFFFFFFF,
     -1, -23, -512, -1230, -567898, -16#FFFFFFFFFF,
     123.123, -234.4355, 1.0e-34, 1.0e64,
     [23, 234, 0.23],
     <<"hogehoge">>, <<"243546rf7g68h798j", 0, 23, 255>>,
     <<"hoasfdafdas][">>,
     [0,42, <<"sum">>, [1,2]], [1,42, nil, [3]],
     42
    ].

basic_test()->
    Tests = test_data(),
    Passed = test_(Tests),
    Passed = length(Tests).

port_test()->
    Tests = test_data(),
    {[Tests],<<>>} = msgpack:unpack(msgpack:pack([Tests])),
    Port = open_port({spawn, "ruby ../test/crosslang.rb"}, [binary]),
    true = port_command(Port, msgpack:pack(Tests) ),
    receive
	{Port, {data, Data}}->  {Tests, <<>>}=msgpack:unpack(Data)
    after 1024-> ?assert(false)   end,
    port_close(Port).

test_p(Len,Term,OrigBin,Len) ->
    {Term, <<>>}=msgpack:unpack(OrigBin);
test_p(I,_,OrigBin,Len) when I < Len->
    <<Bin:I/binary, _/binary>> = OrigBin,
    ?assertEqual({more, undefined}, msgpack:unpack(Bin)).

partial_test()-> % error handling test.
    Term = lists:seq(0, 45),
    Bin=msgpack:pack(Term),
    BinLen = byte_size(Bin),
    [test_p(X, Term, Bin, BinLen) || X <- lists:seq(0,BinLen)].

long_test()->
    Longer = lists:seq(0, 655),
%    Longest = lists:seq(0,12345),
    {Longer, <<>>} = msgpack:unpack(msgpack:pack(Longer)),
%    {Longest, <<>>} = msgpack:unpack(msgpack:pack(Longest)).
    ok.

map_test()->
    Ints = lists:seq(0, 65),
    Map = {[ {X, X*2} || X <- Ints ] ++ [{<<"hage">>, 324}, {43542, [nil, true, false]}]},
    {Map2, <<>>} = msgpack:unpack(msgpack:pack(Map)),
    ?assertEqual(Map, Map2),
    ok.

unknown_test()->
    Tests = [0, 1, 2, 123, 512, 1230, 678908,
	     -1, -23, -512, -1230, -567898,
	     <<"hogehoge">>, <<"243546rf7g68h798j">>,
	     123.123,
	     -234.4355, 1.0e-34, 1.0e64,
	     [23, 234, 0.23],
	     [0,42,<<"sum">>, [1,2]], [1,42, nil, [3]],
	     dict:from_list([{1,2},{<<"hoge">>,nil}]),
	     42
	    ],
    Port = open_port({spawn, "ruby testcase_generator.rb"}, [binary]),
    receive
	{Port, {data, Data}}->
	    compare_all(Tests, msgpack:unpack_all(Data))
    after 1024-> ?assert(false)   end,
    port_close(Port).

test_([]) -> 0;
test_([S|Rest])->
    Pack = msgpack:pack(S),
    ?assertEqual({S, <<>>}, msgpack:unpack(Pack)),
    1+test_(Rest).

other_test()->
    ?assertEqual({more,undefined}, msgpack:unpack(<<>>)).

-endif.
