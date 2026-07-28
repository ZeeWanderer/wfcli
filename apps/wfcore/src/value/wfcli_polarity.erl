%%%-------------------------------------------------------------------
%% Canonical Forma polarity values shared by daemon data and CLI output.
%%%-------------------------------------------------------------------
-module(wfcli_polarity).

-export([normalize/1, symbol/1]).

-doc "Normalize a config or plan polarity to its protocol atom.".
-spec normalize(term()) -> madurai | vazarin | naramon | zenurik | unairu |
                           omni | umbral | umbral_forma | penjaga | none | unknown.
normalize(undefined) -> none;
normalize(null) -> none;
normalize(<<>>) -> none;
normalize(none) -> none;
normalize(unknown) -> unknown;
normalize(madurai) -> madurai;
normalize(vazarin) -> vazarin;
normalize(naramon) -> naramon;
normalize(zenurik) -> zenurik;
normalize(unairu) -> unairu;
normalize(omni) -> omni;
normalize(umbral) -> umbral;
normalize(umbral_forma) -> umbral_forma;
normalize(penjaga) -> penjaga;
normalize(Bin) when is_binary(Bin) -> normalize(binary_to_list(Bin));
normalize(Str) when is_list(Str) ->
    case string:lowercase(Str) of
        "v" -> madurai;
        "d" -> vazarin;
        "-" -> naramon;
        "bar" -> naramon;
        "=" -> zenurik;
        "flame" -> zenurik;
        "unairu" -> unairu;
        "y" -> unairu;
        "u" -> umbral;
        "o" -> omni;
        "p" -> penjaga;
        "" -> none;
        _ -> unknown
    end;
normalize(Atom) when is_atom(Atom) -> normalize(atom_to_list(Atom));
normalize(_) -> unknown.

-doc "Return the stable YAML and terminal symbol for a polarity atom.".
-spec symbol(term()) -> string() | null.
symbol(madurai) -> "V";
symbol(vazarin) -> "D";
symbol(naramon) -> "-";
symbol(zenurik) -> "=";
symbol(unairu) -> "Y";
symbol(umbral) -> "U";
symbol(omni) -> "O";
symbol(penjaga) -> "P";
symbol(none) -> null;
symbol(unknown) -> "unknown";
symbol(_) -> "unknown".
