# Query Language

One query language covers worldstate, mods, items, Codex, enemies, and drops. Syntax is parsed
by `wfcli_query_parse`; `wfcli_entity_query` compiles fields through datasource schemas and owns
matching, sorting, and paging.

## Grammar

```text
expression := or-expression
or         := and-expression (OR and-expression)*
and        := unary ((AND)? unary)*
unary      := NOT unary | primary
primary    := clause | "(" expression ")"
clause     := term | key operator value ("|" value)*
operator   := = | != | ~ | >= | <= | > | < | :
```

- Whitespace between expressions means AND.
- Precedence is `NOT`, `AND`, `OR`; parentheses override it.
- Boolean keywords are uppercase. Lowercase `and`, `or`, and `not` remain search terms.
- Double quotes preserve one substring phrase and make syntax characters literal.
- Backslash escapes the next character.
- `|` means alternatives only inside one field filter. Expression OR is the `OR` keyword.
- `sort=` and unified-query `dataset=` are positive top-level controls, not predicates.

Examples:

```text
braton prime                         # braton AND prime
braton OR burston
(braton OR burston) masteryReq>=8
NOT rarity=common
name="Critical Delay"
file=ExportWeapons_en.json|ExportWarframes_en.json
```

At a shell, preserve query-language quotes with an outer quote style, for example:

```bash
wfcli codex '"critical chance" OR category=Warframes'
```

## Architecture

1. CLI option parsing keeps source/cache/output controls separate and leaves query text opaque.
2. A daemon queue parses the text once with `wfcli_query_parse` into a
   datasource-independent AST.
3. `wfcli_exports_query` or `wfcli_knowledge_query` combines focused-command field flags
   with that AST.
4. `wfcli_entity_query` asks the owning daemon entity module to resolve each field.
5. Compilation validates fields, operators, numbers, and sort keys before execution.
6. The daemon executes against cached typed projections. Worldstate also exposes an explicit
   query-only raw-root entity, so projections add semantics without gating source-tree paths.
7. Focused and unified CLIs use the same formatter modules; neither invokes another CLI.

Field schemas use fixed atom mappings. Never create atoms from query input. Special semantics,
such as mod polarity aliases, stay in the owning entity schema rather than the generic engine.
Worldstate projected columns are query fields through the shared schema registry; raw record
fields remain available as `data.<path>`.

## Design Sources

- [GitHub Code Search syntax](https://docs.github.com/en/search-github/github-code-search/understanding-github-code-search-syntax)
  supplies the main user model: whitespace AND, uppercase boolean operators, quotes,
  qualifiers, parentheses, and narrow escaping.
- [SQLite FTS5](https://www.sqlite.org/fts5.html) confirms explicit boolean precedence and
  implicit AND, but wfcli allows adjacency after a parenthesized expression.
- [PostgreSQL text search](https://www.postgresql.org/docs/current/textsearch-controls.html)
  validates web-search-style implicit AND, phrase quotes, OR, and exclusion.
- [Lucene query syntax](https://lucene.apache.org/core/3_4_0/queryparsersyntax.html) informed
  field filters, grouping, and escaping. wfcli rejects Lucene's default-OR behavior.
- [Elasticsearch query string](https://www.elastic.co/guide/en/elasticsearch/reference/current/query-dsl-query-string-query.html)
  demonstrates why surprising precedence and strict end-user parsers are hazards; wfcli uses
  conventional precedence; daemon admission returns syntax errors to the requesting CLI.

Deliberate exclusions: regex, fuzzy/proximity search, boosts, ranges with bracket syntax, and
symbolic expression `|`. Add syntax only when a concrete wfcli use case needs it.
