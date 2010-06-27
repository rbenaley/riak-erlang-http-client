%% @doc This module contains utilities that the rhc module uses for
%%      translating between HTTP (ibrowse) data and riakc_obj objects.
-module(rhc_obj).

-export([make_riakc_obj/4,
         serialize_riakc_obj/2,
         ctype_from_headers/1]).

-include("raw_http.hrl").
-include("rhc.hrl").

%% HTTP -> riakc_obj

make_riakc_obj(Bucket, Key, Headers, Body) ->
    Vclock = base64:decode(proplists:get_value(?HEAD_VCLOCK, Headers, "")),
    case ctype_from_headers(Headers) of
        {"multipart/mixed", Args} ->
            {"boundary", Boundary} = proplists:lookup("boundary", Args),
            riakc_obj:new_obj(
              Bucket, Key, Vclock,
              decode_siblings(Boundary, Body));
        {_CType, _} ->
            riakc_obj:new_obj(
              Bucket, Key, Vclock,
              [{headers_to_metadata(Headers), list_to_binary(Body)}])
    end.

ctype_from_headers(Headers) ->
    mochiweb_util:parse_header(
      proplists:get_value(?HEAD_CTYPE, Headers)).

vtag_from_headers(Headers) ->
    %% non-sibling uses ETag, sibling uses Etag
    %% (note different capitalization on 't')
    case proplists:lookup("ETag", Headers) of
        {"ETag", ETag} -> ETag;
        none -> proplists:get_value("Etag", Headers)
    end.
           

lastmod_from_headers(Headers) ->
    case proplists:get_value("Last-Modified", Headers) of
        undefined ->
            undefined;
        RfcDate ->
            GS = calendar:datetime_to_gregorian_seconds(
                   httpd_util:convert_request_date(RfcDate)),
            ES = GS-62167219200, %% gregorian seconds of the epoch
            {ES div 1000000, % Megaseconds
             ES rem 1000000, % Seconds
             0}              % Microseconds
    end.

decode_siblings(Boundary, "\r\n"++SibBody) ->
    decode_siblings(Boundary, SibBody);
decode_siblings(Boundary, SibBody) ->
    Parts = webmachine_multipart:get_all_parts(
              list_to_binary(SibBody), Boundary),
    [ {headers_to_metadata([ {binary_to_list(H), binary_to_list(V)}
                             || {H, V} <- Headers ]),
       element(1, split_binary(Body, size(Body)-2))} %% remove trailing \r\n
      || {_, {_, Headers}, Body} <- Parts ].

headers_to_metadata(Headers) ->
    UserMeta = extract_user_metadata(Headers),

    {CType,_} = ctype_from_headers(Headers),
    CUserMeta = dict:store(?MD_CTYPE, CType, UserMeta),

    VTag = vtag_from_headers(Headers),
    VCUserMeta = dict:store(?MD_VTAG, VTag, CUserMeta),

    LVCUserMeta = case lastmod_from_headers(Headers) of
                      undefined ->
                          VCUserMeta;
                      LastMod ->
                          dict:store(?MD_LASTMOD, LastMod, VCUserMeta)
                  end,

    case extract_links(Headers) of
        [] -> LVCUserMeta;
        Links -> dict:store(?MD_LINKS, Links, LVCUserMeta)
    end.

extract_user_metadata(_Headers) ->
    %%TODO
    dict:new().

extract_links(Headers) ->
    {ok, Re} = re:compile("</[^/]+/([^/]+)/([^/]+)>; *riaktag=\"(.*)\""),
    Extractor = fun(L, Acc) ->
                        case re:run(L, Re, [{capture,[1,2,3],binary}]) of
                            {match, [Bucket, Key,Tag]} ->
                                [{{Bucket,Key},Tag}|Acc];
                            nomatch ->
                                Acc
                        end
                end,
    LinkHeader = proplists:get_value(?HEAD_LINK, Headers, []),
    lists:foldl(Extractor, [], string:tokens(LinkHeader, ",")).


%% riakc_obj -> HTTP

serialize_riakc_obj(Rhc, Object) ->
    {make_headers(Rhc, Object), make_body(Object)}.

make_headers(Rhc, Object) ->
    MD = riakc_obj:get_update_metadata(Object),
    CType = case dict:find(?MD_CTYPE, MD) of
                {ok, C} when is_list(C) -> C;
                {ok, C} when is_binary(C) -> binary_to_list(C);
                error -> "application/octet-stream"
            end,
    Links = case dict:find(?MD_LINKS, MD) of
                {ok, L} -> L;
                error   -> []
            end,
    VClock = riakc_obj:vclock(Object),
    lists:flatten(
      [{?HEAD_CTYPE, CType},
       [ {?HEAD_LINK, encode_links(Rhc, Links)} || Links =/= [] ],
       [ {?HEAD_VCLOCK, base64:encode_to_string(VClock)}
         || VClock =/= undefined ]
       | encode_user_metadata(MD) ]).

encode_links(_, []) -> [];
encode_links(#rhc{prefix=Prefix}, Links) ->
    {{FirstBucket, FirstKey}, FirstTag} = hd(Links),
    lists:foldl(
      fun({{Bucket, Key}, Tag}, Acc) ->
              [format_link(Prefix, Bucket, Key, Tag), ", "|Acc]
      end,
      format_link(Prefix, FirstBucket, FirstKey, FirstTag),
      tl(Links)).

encode_user_metadata(_Metadata) ->
    %% TODO
    [].

format_link(Prefix, Bucket, Key, Tag) ->
    io_lib:format("</~s/~s/~s>; riaktag=\"~s\"",
                  [Prefix, Bucket, Key, Tag]).

make_body(Object) ->
    case riakc_obj:get_update_value(Object) of
        Val when is_binary(Val) -> Val;
        Val when is_list(Val) ->
            case is_iolist(Val) of
                true -> Val;
                false -> term_to_binary(Val)
            end;
        Val ->
            term_to_binary(Val)
    end.

is_iolist(Binary) when is_binary(Binary) -> true;
is_iolist(List) when is_list(List) ->
    lists:all(fun is_iolist/1, List);
is_iolist(_) -> false.
