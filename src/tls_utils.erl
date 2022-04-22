-module(tls_utils).

-export([
    get_subject_identity/1,
    parse_subject/1
]).

get_subject_identity(DerCert) ->
    {_SerialNumber, SubjectId} = public_key:pkix_subject_id(DerCert),
    parse_subject(SubjectId).

% {147912936552408153545750551425556152743,
%  {rdnSequence,
%   [[{'AttributeTypeAndValue',{2,5,4,6},"US"}],
%    [{'AttributeTypeAndValue',
%      {2,5,4,10},
%      {utf8String,<<"Good Guys Inc.">>}}],
%    [{'AttributeTypeAndValue',
%      {2,5,4,3},
%      {utf8String,<<"dev-client">>}}]]}}

parse_subject({'rdnSequence', Seq}) ->
    Parsed = parse_type_value(Seq, []),
    list_to_binary(Parsed).

parse_type_value([], Acc) ->
    Acc;
parse_type_value([[{'AttributeTypeAndValue', {2, 5, 4, 3}, {'utf8String', Value}}] | T], Acc) ->
    F = io_lib:format("CN=~s;", [Value]),
    parse_type_value(T, [Acc | F]);
parse_type_value([[{'AttributeTypeAndValue', {2, 5, 4, 4}, {'utf8String', Value}}] | T], Acc) ->
    F = io_lib:format("SN=~s;", [Value]),
    parse_type_value(T, [Acc | F]);
parse_type_value([[{'AttributeTypeAndValue', {2, 5, 4, 5}, {'utf8String', Value}}] | T], Acc) ->
    F = io_lib:format("SERIALNUMBER=~s;", [Value]),
    parse_type_value(T, [Acc | F]);
parse_type_value([[{'AttributeTypeAndValue', {2, 5, 4, 6}, Value}] | T], Acc) ->
    F = io_lib:format("C=~s;", [Value]),
    parse_type_value(T, [Acc | F]);
parse_type_value([[{'AttributeTypeAndValue', {2, 5, 4, 7}, {'utf8String', Value}}] | T], Acc) ->
    F = io_lib:format("L=~s;", [Value]),
    parse_type_value(T, [Acc | F]);
parse_type_value([[{'AttributeTypeAndValue', {2, 5, 4, 8}, {'utf8String', Value}}] | T], Acc) ->
    F = io_lib:format("S=~s;", [Value]),
    parse_type_value(T, [Acc | F]);
parse_type_value([[{'AttributeTypeAndValue', {2, 5, 4, 9}, {'utf8String', Value}}] | T], Acc) ->
    F = io_lib:format("STREET=~s;", [Value]),
    parse_type_value(T, [Acc | F]);
parse_type_value([[{'AttributeTypeAndValue', {2, 5, 4, 10}, {'utf8String', Value}}] | T], Acc) ->
    F = io_lib:format("O=~s;", [Value]),
    parse_type_value(T, [Acc | F]);
parse_type_value([[{'AttributeTypeAndValue', {2, 5, 4, 11}, {'utf8String', Value}}] | T], Acc) ->
    F = io_lib:format("OU=~s;", [Value]),
    parse_type_value(T, [Acc | F]);
parse_type_value([[{'AttributeTypeAndValue', {2, 5, 4, 12}, {'utf8String', Value}}] | T], Acc) ->
    F = io_lib:format("T=~s;", [Value]),
    parse_type_value(T, [Acc | F]);
parse_type_value([_ | T], Acc) ->
    parse_type_value(T, Acc).
