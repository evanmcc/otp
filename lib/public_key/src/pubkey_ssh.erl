%%
%% %CopyrightBegin%
%%
%% Copyright Ericsson AB 2011-2014. All Rights Reserved.
%%
%% The contents of this file are subject to the Erlang Public License,
%% Version 1.1, (the "License"); you may not use this file except in
%% compliance with the License. You should have received a copy of the
%% Erlang Public License along with this software. If not, it can be
%% retrieved online at http://www.erlang.org/.
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and limitations
%% under the License.
%%
%% %CopyrightEnd%
%%
-module(pubkey_ssh).

-include("public_key.hrl").

-export([decode/2, encode/2]).

-define(UINT32(X), X:32/unsigned-big-integer).
%% Max encoded line length is 72, but conformance examples use 68
%% Comment from rfc 4716: "The following are some examples of public
%% key files that are compliant (note that the examples all wrap
%% before 72 bytes to meet IETF document requirements; however, they
%% are still compliant.)" So we choose to use 68 also.
-define(ENCODED_LINE_LENGTH, 68).

%%====================================================================
%% Internal application API
%%====================================================================

%%--------------------------------------------------------------------
-spec decode(binary(), public_key | public_key:ssh_file()) -> 
		    [{public_key:public_key(), Attributes::list()}].
%%
%% Description: Decodes a ssh file-binary.
%%--------------------------------------------------------------------
decode(Bin, public_key)->
    case binary:match(Bin, begin_marker()) of
	nomatch ->
	    openssh_decode(Bin, openssh_public_key);
	_ ->
	    rfc4716_decode(Bin)
    end;
decode(Bin, rfc4716_public_key) ->
    rfc4716_decode(Bin);
decode(Bin, Type) ->
    openssh_decode(Bin, Type).

%%--------------------------------------------------------------------
-spec encode([{public_key:public_key(), Attributes::list()}], public_key:ssh_file()) ->
		    binary().
%%
%% Description: Encodes a list of ssh file entries.
%%--------------------------------------------------------------------
encode(Entries, Type) ->
    iolist_to_binary(lists:map(fun({Key, Attributes}) ->
					      do_encode(Type, Key, Attributes)
				      end, Entries)).

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------
begin_marker() ->
    <<"---- BEGIN SSH2 PUBLIC KEY ----">>.
end_marker() ->
    <<"---- END SSH2 PUBLIC KEY ----">>.

rfc4716_decode(Bin) ->
    Lines = binary:split(Bin, <<"\n">>, [global]),
    do_rfc4716_decode(Lines, []).

do_rfc4716_decode([<<"---- BEGIN SSH2 PUBLIC KEY ----", _/binary>> | Lines], Acc) ->
    do_rfc4716_decode(Lines, Acc);
%% Ignore empty lines before or after begin/end - markers.
do_rfc4716_decode([<<>> | Lines], Acc) ->
    do_rfc4716_decode(Lines, Acc);
do_rfc4716_decode([], Acc) ->
    lists:reverse(Acc);
do_rfc4716_decode(Lines, Acc) ->
    {Headers, PubKey, Rest} = rfc4716_decode_lines(Lines, []),
    case Headers of
	[_|_] ->
	    do_rfc4716_decode(Rest, [{PubKey, [{headers, Headers}]} | Acc]);
	_  ->
	    do_rfc4716_decode(Rest, [{PubKey, []} | Acc])
    end.

rfc4716_decode_lines([Line | Lines], Acc) ->
    case binary:last(Line) of
	$\\ ->
	    NewLine = binary:replace(Line,<<"\\">>, hd(Lines), []),
	    rfc4716_decode_lines([NewLine | tl(Lines)], Acc);
	_ ->
	    rfc4716_decode_line(Line, Lines, Acc)
    end.

rfc4716_decode_line(Line, Lines, Acc) ->
    case binary:split(Line, <<":">>) of
	[Tag, Value] ->
	    rfc4716_decode_lines(Lines, [{string_decode(Tag), unicode_decode(Value)} | Acc]);
	_ ->
	    {Body, Rest} = join_entry([Line | Lines], []),
	    {lists:reverse(Acc), rfc4716_pubkey_decode(base64:mime_decode(Body)), Rest}
    end.

join_entry([<<"---- END SSH2 PUBLIC KEY ----", _/binary>>| Lines], Entry) ->
    {lists:reverse(Entry), Lines};
join_entry([Line | Lines], Entry) ->
    join_entry(Lines, [Line | Entry]).


rfc4716_pubkey_decode(<<?UINT32(Len), Type:Len/binary,
			?UINT32(SizeE), E:SizeE/binary,
			?UINT32(SizeN), N:SizeN/binary>>) when Type == <<"ssh-rsa">> ->
    #'RSAPublicKey'{modulus = erlint(SizeN, N),
		    publicExponent = erlint(SizeE, E)};

rfc4716_pubkey_decode(<<?UINT32(Len), Type:Len/binary,
			?UINT32(SizeP), P:SizeP/binary,
			?UINT32(SizeQ), Q:SizeQ/binary,
			?UINT32(SizeG), G:SizeG/binary,
			?UINT32(SizeY), Y:SizeY/binary>>) when Type == <<"ssh-dss">> ->
    {erlint(SizeY, Y),
     #'Dss-Parms'{p = erlint(SizeP, P),
		  q = erlint(SizeQ, Q),
		  g = erlint(SizeG, G)}}.

openssh_decode(Bin, FileType) ->
    Lines = binary:split(Bin, <<"\n">>, [global]),
    do_openssh_decode(FileType, Lines, []).

do_openssh_decode(_, [], Acc) ->
    lists:reverse(Acc);
%% Ignore empty lines
do_openssh_decode(FileType, [<<>> | Lines], Acc) ->
    do_openssh_decode(FileType, Lines, Acc);
%% Ignore lines that start with #
do_openssh_decode(FileType,[<<"#", _/binary>> | Lines], Acc) ->
    do_openssh_decode(FileType, Lines, Acc);
do_openssh_decode(auth_keys = FileType, [Line | Lines], Acc) ->
    case decode_auth_keys(Line) of
	{ssh2,  {options, [Options, KeyType, Base64Enc| Comment]}} ->
	    do_openssh_decode(FileType, Lines,
			      [{openssh_pubkey_decode(KeyType, Base64Enc), 
				decode_comment(Comment) ++ [{options, comma_list_decode(Options)}]} | Acc]);
	{ssh2, {no_options, [KeyType, Base64Enc| Comment]}} ->
	    do_openssh_decode(FileType, Lines,
			      [{openssh_pubkey_decode(KeyType, Base64Enc), 
				decode_comment(Comment)} | Acc]);
	{ssh1, {options, [Options, Bits, Exponent, Modulus | Comment]}} ->
	    do_openssh_decode(FileType, Lines,
			      [{ssh1_rsa_pubkey_decode(Modulus, Exponent),
				decode_comment(Comment) ++ [{options, comma_list_decode(Options)},
							    {bits, integer_decode(Bits)}]
			       } | Acc]);
	{ssh1, {no_options, [Bits, Exponent, Modulus | Comment]}} ->
	    do_openssh_decode(FileType, Lines,
			      [{ssh1_rsa_pubkey_decode(Modulus, Exponent),
				decode_comment(Comment) ++ [{bits, integer_decode(Bits)}]
			       } | Acc])
    end;

do_openssh_decode(known_hosts = FileType, [Line | Lines], Acc) ->
    case decode_known_hosts(Line) of
	{ssh2, [HostNames, KeyType, Base64Enc| Comment]} ->
	    do_openssh_decode(FileType, Lines,
			      [{openssh_pubkey_decode(KeyType, Base64Enc), 
				decode_comment(Comment) ++ 
				    [{hostnames, comma_list_decode(HostNames)}]}| Acc]);
	{ssh1, [HostNames, Bits, Exponent, Modulus | Comment]} ->
	    do_openssh_decode(FileType, Lines,
			      [{ssh1_rsa_pubkey_decode(Modulus, Exponent), 
				decode_comment(Comment) ++ 
				    [{hostnames, comma_list_decode(HostNames)},
				     {bits, integer_decode(Bits)}]} 
			       | Acc])
    end;

do_openssh_decode(openssh_public_key = FileType, [Line | Lines], Acc) ->
    case split_n(2, Line, []) of
	[KeyType, Base64Enc] when KeyType == <<"ssh-rsa">>;
				  KeyType == <<"ssh-dss">> ->
	    do_openssh_decode(FileType, Lines,
			      [{openssh_pubkey_decode(KeyType, Base64Enc),
				[]} | Acc]);
	[KeyType, Base64Enc | Comment0] when KeyType == <<"ssh-rsa">>;
					     KeyType == <<"ssh-dss">> ->
	    Comment = string:strip(string_decode(iolist_to_binary(Comment0)), right, $\n),
	    do_openssh_decode(FileType, Lines,
			      [{openssh_pubkey_decode(KeyType, Base64Enc),
				[{comment, Comment}]} | Acc])
    end.

decode_comment([]) ->
    [];
decode_comment(Comment) ->
    [{comment, string_decode(iolist_to_binary(Comment))}].

openssh_pubkey_decode(<<"ssh-rsa">>, Base64Enc) ->
    <<?UINT32(StrLen), _:StrLen/binary,
      ?UINT32(SizeE), E:SizeE/binary,
      ?UINT32(SizeN), N:SizeN/binary>>
	= base64:mime_decode(Base64Enc),
    #'RSAPublicKey'{modulus = erlint(SizeN, N),
		    publicExponent = erlint(SizeE, E)};

openssh_pubkey_decode(<<"ssh-dss">>, Base64Enc) ->
    <<?UINT32(StrLen), _:StrLen/binary,
      ?UINT32(SizeP), P:SizeP/binary,
      ?UINT32(SizeQ), Q:SizeQ/binary,
      ?UINT32(SizeG), G:SizeG/binary,
      ?UINT32(SizeY), Y:SizeY/binary>>
	= base64:mime_decode(Base64Enc),
    {erlint(SizeY, Y),
     #'Dss-Parms'{p = erlint(SizeP, P),
		  q = erlint(SizeQ, Q),
		  g = erlint(SizeG, G)}};
openssh_pubkey_decode(KeyType, Base64Enc) ->
    {KeyType, base64:mime_decode(Base64Enc)}.

erlint(MPIntSize, MPIntValue) ->
    Bits= MPIntSize * 8,
    <<Integer:Bits/integer>> = MPIntValue,
    Integer.

ssh1_rsa_pubkey_decode(MBin, EBin) ->
    #'RSAPublicKey'{modulus = integer_decode(MBin),
		    publicExponent = integer_decode(EBin)}.

integer_decode(BinStr) ->
    list_to_integer(binary_to_list(BinStr)).

string_decode(BinStr) ->
    unicode_decode(BinStr).

unicode_decode(BinStr) ->
    unicode:characters_to_list(BinStr).

comma_list_decode(BinOpts) ->
    CommaList = binary:split(BinOpts, <<",">>, [global]),
    lists:map(fun(Item) ->
		      binary_to_list(Item)
	      end, CommaList).

do_encode(rfc4716_public_key, Key, Attributes) ->
    rfc4716_encode(Key, proplists:get_value(headers, Attributes, []), []);

do_encode(Type, Key, Attributes) ->
    openssh_encode(Type, Key, Attributes).

rfc4716_encode(Key, [],[]) ->
    iolist_to_binary([begin_marker(),"\n",
			     split_lines(base64:encode(ssh2_pubkey_encode(Key))),
			     "\n", end_marker(), "\n"]);
rfc4716_encode(Key, [], [_|_] = Acc) ->
    iolist_to_binary([begin_marker(), "\n",
			     lists:reverse(Acc),
			     split_lines(base64:encode(ssh2_pubkey_encode(Key))),
			     "\n", end_marker(), "\n"]);
rfc4716_encode(Key, [ Header | Headers], Acc) ->
    LinesStr = rfc4716_encode_header(Header),
    rfc4716_encode(Key, Headers, [LinesStr | Acc]).

rfc4716_encode_header({Tag, Value}) ->
    TagLen = length(Tag),
    ValueLen = length(Value),
    case TagLen + 1 + ValueLen of
	N when N > ?ENCODED_LINE_LENGTH ->
	    NumOfChars =  ?ENCODED_LINE_LENGTH - (TagLen + 1),
	    {First, Rest} = lists:split(NumOfChars, Value),
	    [Tag,":" , First, [$\\], "\n", rfc4716_encode_value(Rest) , "\n"];
	_ ->
	    [Tag, ":", Value, "\n"]
    end.

rfc4716_encode_value(Value) ->
    case length(Value) of
	N when N > ?ENCODED_LINE_LENGTH ->
	    {First, Rest} = lists:split(?ENCODED_LINE_LENGTH, Value),
	    [First, [$\\], "\n", rfc4716_encode_value(Rest)];
	_ ->
	    Value
    end.

openssh_encode(openssh_public_key, Key, Attributes) ->
    Comment = proplists:get_value(comment, Attributes, ""),
    Enc = base64:encode(ssh2_pubkey_encode(Key)),
    iolist_to_binary([key_type(Key), " ",  Enc,  " ", Comment, "\n"]);

openssh_encode(auth_keys, Key, Attributes) ->
    Comment = proplists:get_value(comment, Attributes, ""),
    Options = proplists:get_value(options, Attributes, undefined),
    Bits = proplists:get_value(bits, Attributes, undefined),
    case Bits of
	undefined ->
	    openssh_ssh2_auth_keys_encode(Options, Key, Comment);
	_ ->
	    openssh_ssh1_auth_keys_encode(Options, Bits, Key, Comment)
    end;
openssh_encode(known_hosts, Key, Attributes) ->
    Comment = proplists:get_value(comment, Attributes, ""),
    Hostnames = proplists:get_value(hostnames, Attributes),
    Bits = proplists:get_value(bits, Attributes, undefined),
    case Bits of
	undefined ->
	    openssh_ssh2_know_hosts_encode(Hostnames, Key, Comment);
	_ ->
	    openssh_ssh1_known_hosts_encode(Hostnames, Bits, Key, Comment)
    end.

openssh_ssh2_auth_keys_encode(undefined, Key, Comment) ->
    iolist_to_binary([key_type(Key)," ",  base64:encode(ssh2_pubkey_encode(Key)), line_end(Comment)]);
openssh_ssh2_auth_keys_encode(Options, Key, Comment) ->
    iolist_to_binary([comma_list_encode(Options, []), " ",
			     key_type(Key)," ", base64:encode(ssh2_pubkey_encode(Key)), line_end(Comment)]).

openssh_ssh1_auth_keys_encode(undefined, Bits,
			      #'RSAPublicKey'{modulus = N, publicExponent = E},
			      Comment) ->
    iolist_to_binary([integer_to_list(Bits), " ", integer_to_list(E), " ", integer_to_list(N),
			     line_end(Comment)]);
openssh_ssh1_auth_keys_encode(Options, Bits,
			      #'RSAPublicKey'{modulus = N, publicExponent = E},
			      Comment) ->
    iolist_to_binary([comma_list_encode(Options, []), " ", integer_to_list(Bits),
			     " ", integer_to_list(E), " ", integer_to_list(N), line_end(Comment)]).

openssh_ssh2_know_hosts_encode(Hostnames, Key, Comment) ->
    iolist_to_binary([comma_list_encode(Hostnames, []), " ",
			     key_type(Key)," ",  base64:encode(ssh2_pubkey_encode(Key)), line_end(Comment)]).

openssh_ssh1_known_hosts_encode(Hostnames, Bits,
				#'RSAPublicKey'{modulus = N, publicExponent = E},
				Comment) ->
    iolist_to_binary([comma_list_encode(Hostnames, [])," ", integer_to_list(Bits)," ",
			     integer_to_list(E)," ", integer_to_list(N), line_end(Comment)]).

line_end("") ->
    "\n";
line_end(Comment) ->
    [" ", Comment, "\n"].

key_type(#'RSAPublicKey'{}) ->
    <<"ssh-rsa">>;
key_type({_, #'Dss-Parms'{}}) ->
    <<"ssh-dss">>.

comma_list_encode([Option], [])  ->
    Option;
comma_list_encode([Option], Acc) ->
    Acc ++ "," ++ Option;
comma_list_encode([Option | Rest], []) ->
    comma_list_encode(Rest, Option);
comma_list_encode([Option | Rest], Acc) ->
    comma_list_encode(Rest, Acc ++ "," ++ Option).

ssh2_pubkey_encode(#'RSAPublicKey'{modulus = N, publicExponent = E}) ->
    TypeStr = <<"ssh-rsa">>,
    StrLen = size(TypeStr),
    EBin = mpint(E),
    NBin = mpint(N),
    <<?UINT32(StrLen), TypeStr:StrLen/binary,
      EBin/binary,
      NBin/binary>>;
ssh2_pubkey_encode({Y,  #'Dss-Parms'{p = P, q = Q, g = G}}) ->
    TypeStr = <<"ssh-dss">>,
    StrLen = size(TypeStr),
    PBin = mpint(P),
    QBin = mpint(Q),
    GBin = mpint(G),
    YBin = mpint(Y),
    <<?UINT32(StrLen), TypeStr:StrLen/binary,
      PBin/binary,
      QBin/binary,
      GBin/binary,
      YBin/binary>>.

is_key_field(<<"ssh-dss">>) ->
    true;
is_key_field(<<"ssh-rsa">>) ->
    true;
is_key_field(<<"ecdsa-sha2-nistp256">>) ->
    true;
is_key_field(<<"ecdsa-sha2-nistp384">>) ->
    true;
is_key_field(<<"ecdsa-sha2-nistp521">>) ->
    true;
is_key_field(_) ->
    false.

is_bits_field(Part) ->
    try list_to_integer(binary_to_list(Part)) of
	_ ->
	    true
    catch _:_ ->
	    false
    end.

split_lines(<<Text:?ENCODED_LINE_LENGTH/binary>>) ->
    [Text];
split_lines(<<Text:?ENCODED_LINE_LENGTH/binary, Rest/binary>>) ->
    [Text, $\n | split_lines(Rest)];
split_lines(Bin) ->
    [Bin].

decode_auth_keys(Line) ->
    [First, Rest] = binary:split(Line, <<" ">>, []),
    case is_key_field(First) of
	true  ->
	    {ssh2, decode_auth_keys_ssh2(First, Rest)};
	false ->
	    case is_bits_field(First) of
		true ->
		    {ssh1, decode_auth_keys_ssh1(First, Rest)};
		false ->
		    decode_auth_keys(First, Rest)
	    end
    end.

decode_auth_keys(First, Line) ->
    [Second, Rest] = binary:split(Line, <<" ">>, []),
    case is_key_field(Second) of
	true -> 
	    {ssh2, decode_auth_keys_ssh2(First, Second, Rest)};
	false ->
	    case is_bits_field(Second) of
		true -> 
		    {ssh1, decode_auth_keys_ssh1(First, Second, Rest)};
		false ->
		    decode_auth_keys(<<First/binary, Second/binary>>, Rest)
	    end
    end.

decode_auth_keys_ssh2(KeyType, Rest) ->
    {no_options, [KeyType | split_n(1, Rest,  [])]}.

decode_auth_keys_ssh2(Options, Next, Rest) ->
    {options, [Options, Next | split_n(1, Rest,  [])]}.

decode_auth_keys_ssh1(Options, Next, Rest) ->
    {options, [Options, Next | split_n(2, Rest,  [])]}.

decode_auth_keys_ssh1(First, Rest) ->
    {no_options, [First | split_n(2, Rest, [])]}.

decode_known_hosts(Line) ->
    [First, Rest] = binary:split(Line, <<" ">>, []),
    [Second, Rest1] = binary:split(Rest, <<" ">>, []),

    case is_bits_field(Second) of
	true ->
	    {ssh1, decode_known_hosts_ssh1(First, Second, Rest1)};
	false ->
	    {ssh2, decode_known_hosts_ssh2(First, Second, Rest1)}
    end.

decode_known_hosts_ssh1(Hostnames, Bits, Rest) ->
    [Hostnames, Bits | split_n(2, Rest,  [])].

decode_known_hosts_ssh2(Hostnames, KeyType, Rest) ->
    [Hostnames, KeyType | split_n(1, Rest,  [])].

split_n(0, <<>>, Acc) ->
    lists:reverse(Acc);
split_n(0, Bin, Acc) ->
    lists:reverse([Bin | Acc]);
split_n(N, Bin, Acc) ->
    case binary:split(Bin, <<" ">>, []) of
	[First, Rest] ->
	    split_n(N-1, Rest, [First | Acc]);
	[Last] ->
	    split_n(0, <<>>, [Last | Acc])
    end.
%% large integer in a binary with 32bit length
%% MP representaion  (SSH2)
mpint(X) when X < 0 -> mpint_neg(X);
mpint(X) -> mpint_pos(X).

mpint_neg(X) ->
    Bin = int_to_bin_neg(X, []),
    Sz = byte_size(Bin),
    <<?UINT32(Sz), Bin/binary>>.
    
mpint_pos(X) ->
    Bin = int_to_bin_pos(X, []),
    <<MSB,_/binary>> = Bin,
    Sz = byte_size(Bin),
    if MSB band 16#80 == 16#80 ->
	    <<?UINT32((Sz+1)), 0, Bin/binary>>;
       true ->
	    <<?UINT32(Sz), Bin/binary>>
    end.

int_to_bin_pos(0,Ds=[_|_]) ->
    list_to_binary(Ds);
int_to_bin_pos(X,Ds) ->
    int_to_bin_pos(X bsr 8, [(X band 255)|Ds]).

int_to_bin_neg(-1, Ds=[MSB|_]) when MSB >= 16#80 ->
    list_to_binary(Ds);
int_to_bin_neg(X,Ds) ->
    int_to_bin_neg(X bsr 8, [(X band 255)|Ds]).
