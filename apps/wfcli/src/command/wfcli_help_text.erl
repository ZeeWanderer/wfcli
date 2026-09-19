-module(wfcli_help_text).

-export([query_guide/0, query_examples/0]).

query_guide() ->
    [
        "  - Adjacent terms are ANDed. Use uppercase OR, AND, NOT, and parentheses.\n",
        "  - Precedence: NOT, then AND, then OR. Quoted text matches one substring phrase.\n",
        "  - Operators: =, !=, ~, >=, <=, >, <, or key:value for defaults.\n",
        "  - Inside one filter, value1|value2 means either value; use OR between expressions.\n",
        "  - Backslash escapes the next syntax character. Boolean keywords are uppercase only.\n",
        "  - Sorting: sort=field or sort=-field (desc).\n"
    ].

query_examples() ->
    [
        "  query: wfcli query \"type=Fissure void\"\n",
        "  query: wfcli query \"type=Fissure|Alert data.MissionType=MT_DEFENSE\"\n",
        "  query: wfcli query '(fissure OR alert) NOT expired'\n",
        "  query: wfcli query \"type=Alert sort=expiry\"\n",
        "  query: wfcli watch --spec \"alerts:reward~endo\"\n",
        "  query: wfcli watch --spec \"fissures:extract=data.Node\"\n"
    ].
