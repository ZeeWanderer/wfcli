%%%-------------------------------------------------------------------
%% Fuzzy Warframe Market item-name resolution for OCR labels.
%%%-------------------------------------------------------------------
-module(wfcli_market_resolver).

-export([resolve/3]).

-doc "Resolve each label to ranked Market items using normalized edit distance.".
-spec resolve([binary()], [map()], 1..5) -> [map()].
resolve(Labels, Items, Limit) ->
    Candidates = [Candidate || Item <- Items,
                                Candidate <- [candidate(Item)],
                                Candidate =/= undefined],
    [#{label => Label, matches => matches(Label, Candidates, Limit)} || Label <- Labels].

candidate(Item) ->
    Slug = maps:get(<<"slug">>, Item, <<>>),
    Name = item_name(Item),
    English = maps:get(<<"en">>, maps:get(<<"i18n">>, Item, #{}), #{}),
    Normalized = normalize(Name),
    case {Slug, Normalized} of
        {<<>>, _} -> undefined;
        {_, []} -> undefined;
        _ -> #{name => Name, slug => Slug, normalized => Normalized,
               ducats => maps:get(<<"ducats">>, Item, undefined),
               game_ref => maps:get(<<"gameRef">>, Item, undefined),
               icon => maps:get(<<"icon">>, English, undefined),
               thumb => maps:get(<<"thumb">>, English, undefined),
               sub_icon => maps:get(<<"subIcon">>, English, undefined)}
    end.

item_name(Item) ->
    I18n = maps:get(<<"i18n">>, Item, #{}),
    English = maps:get(<<"en">>, I18n, #{}),
    maps:get(<<"name">>, English, maps:get(<<"slug">>, Item, <<>>)).

matches(Label, Candidates, Limit) ->
    NormalizedLabel = normalize(Label),
    Ranked = lists:sort(
      fun candidate_before/2,
      [score(NormalizedLabel, Candidate) || Candidate <- Candidates]),
    [public_match(Match) || Match <- lists:sublist(Ranked, Limit)].

score(Label, Candidate0 = #{name := Name, slug := Slug, normalized := Candidate}) ->
    Distance = levenshtein(Label, Candidate),
    Length = max(length(Label), length(Candidate)),
    Confidence = case Length of
        0 -> 1.0;
        _ -> round(max(0.0, 1.0 - Distance / Length) * 10000) / 10000
    end,
    Candidate0#{name => Name, slug => Slug, normalized => Candidate,
                distance => Distance, confidence => Confidence}.

candidate_before(Left, Right) ->
    LeftKey = {-maps:get(confidence, Left), maps:get(distance, Left),
               maps:get(normalized, Left), maps:get(slug, Left)},
    RightKey = {-maps:get(confidence, Right), maps:get(distance, Right),
                maps:get(normalized, Right), maps:get(slug, Right)},
    LeftKey < RightKey.

public_match(Candidate = #{name := Name, slug := Slug, distance := Distance,
                           confidence := Confidence}) ->
    Match = #{name => Name, slug => Slug, distance => Distance,
              confidence => Confidence},
    Match1 = lists:foldl(
      fun(Key, Acc) ->
          case maps:get(Key, Candidate, undefined) of
              undefined -> Acc;
              Value -> Acc#{Key => Value}
          end
      end,
      Match,
      [game_ref, icon, thumb, sub_icon]),
    case maps:get(ducats, Candidate, undefined) of
        Value when is_integer(Value), Value >= 0 -> Match1#{ducats => Value};
        _ -> Match1
    end.

normalize(Value) ->
    Lower = string:casefold(wfcli_text:to_list(Value)),
    Normalized = re:replace(Lower, "[^\\p{L}\\p{N}]+", " ",
                            [global, unicode, ucp, {return, list}]),
    string:trim(Normalized).

levenshtein(Left, Right) when length(Left) < length(Right) ->
    levenshtein(Right, Left);
levenshtein(Left, Right) ->
    Initial = lists:seq(0, length(Right)),
    {_RowNumber, Final} = lists:foldl(
      fun(Char, {RowNumber, Previous}) ->
          {RowNumber + 1, distance_row(Char, Right, Previous, RowNumber)}
      end,
      {1, Initial},
      Left),
    lists:last(Final).

distance_row(Char, Other, [PreviousHead | PreviousTail], RowNumber) ->
    lists:reverse(
      distance_cells(Char, Other, PreviousTail, PreviousHead, RowNumber,
                     [RowNumber])).

distance_cells(_Char, [], [], _Diagonal, _Left, Acc) -> Acc;
distance_cells(Char, [OtherChar | Other], [Up | Previous], Diagonal, Left, Acc) ->
    Substitution = Diagonal + case Char =:= OtherChar of true -> 0; false -> 1 end,
    Current = min(min(Up + 1, Left + 1), Substitution),
    distance_cells(Char, Other, Previous, Up, Current, [Current | Acc]).
