# scenario 401 — recommendation products_list vs products (data-schema mismatch, CODE/RCR)
groundtruth: RCI=recommendation-service; RCR=recommendation_server.py get_product_list uses cat_response.products_list (proto field is `products`); fix=use products. faultfree=demo:2.0.1-recommendation.
oracle: recommendation `products_list`/AttributeError log count -> 0 (independent of NEAT). faultfree control PASSED (0).
| arm | RCI | RCR | fix | verified | cmds | RESOLVED |
|-----|-----|-----|-----|----------|------|----------|
| neat | recommendation ✓ | server.py:85,96 ✓ | products_list->products ✓ | fix == faultfree (control passed); oracle-window FAIL was artifact | 4 | YES |
| code | recommendation ✓ | server.py:85,96 ✓ | products_list->products ✓ | oracle PASS (0 errors) | 4 | YES |
VERDICT: both RESOLVED, TIE (4v4). 401 is code-findable (proto contract) -> no fusion gap, as expected (PRAXIS's code-solvable ~33%). NEAT localized via fused runtime error string (instant); code reasoned from proto.
HARNESS BUG FOUND+FIXED (mine, not NEAT): oracle --since window spanned rollout transition -> false FAIL. Fixed: settle 100s + post-settle 45s window.
