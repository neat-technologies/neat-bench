# scenario 401 — recommendation products_list vs products (data-schema mismatch, CODE/RCR)
groundtruth: RCI=recommendation-service; RCR=recommendation_server.py get_product_list uses cat_response.products_list (proto field is `products`); fix=use products. faultfree=demo:2.0.1-recommendation.
oracle: recommendation `products_list`/AttributeError log count -> 0 (independent of NEAT). faultfree control PASSED (0).
| arm | RCI | RCR | fix | verified | cmds | RESOLVED |
|-----|-----|-----|-----|----------|------|----------|
| neat | recommendation ✓ | server.py:85,96 ✓ | products_list->products ✓ | fix == faultfree (control passed); oracle-window FAIL was artifact | 4 | YES |
| code | recommendation ✓ | server.py:85,96 ✓ | products_list->products ✓ | oracle PASS (0 errors) | 4 | YES |
VERDICT: both RESOLVED, TIE (4v4). 401 is code-findable (proto contract) -> no fusion gap, as expected (PRAXIS's code-solvable ~33%). NEAT localized via fused runtime error string (instant); code reasoned from proto.
HARNESS BUG FOUND+FIXED (mine, not NEAT): oracle --since window spanned rollout transition -> false FAIL. Fixed: settle 100s + post-settle 45s window.

## 401 RE-RUN with FULL NEAT ARSENAL (neat2) — after Cem's "you're using neat as an otel feeder" correction
neat (full arsenal): 12 cmds, CORRECT find+fix. DECISIVE queries: `neat search "get_product_list"` (SYMBOL-GRAIN fusion join: recommendation_server.py#get_product_list -> proto ListProductsResponse.GetProducts, proving field is `products`, NO products_list symbol exists — found via graph, not grep); `neat divergences` (missing-observed frontend->RecommendationService = declared call, no traffic = rec dead); `neat blast-radius` (5 nodes, storefront-wide impact).
CONFOUNDS: (a) 3 queries (incidents/root-cause/ask) returned 500 "Invalid string length" -> FILED #1083 (unbounded incident serialization on 5.5h daemon) -> inflated the count; with those working, root-cause alone gives it (as in the fresh-daemon 4-cmd run). (b) command-count metric doesn't reward NEAT's richer output (blast radius, symbol provenance) vs code's bare 4.
FILED FROM THIS RUN: #1082 (divergences miss symbol/field-grain mismatch), #1083 (incidents/root-cause/ask 500 on large incident store). Both dispatched to coders.
