# scenario 411 — recommendation validate_product_format inverted branches (logic bug, CODE/RCR)
groundtruth: RCI=recommendation; RCR=recommendation_server.py validate_product_format if/else inverted -> always raises AssertionError("Unmet validation constraint") -> aborts every ListRecommendations. fix=swap branches. (injected function, absent in faultfree.)
| arm | RCI | RCR | fix | cmds | RESOLVED |
|-----|-----|-----|-----|------|----------|
| neat | recommendation ✓ | server.py:145 ✓ | swap if/else ✓ | 7 | pending-verify |
| code | recommendation ✓ | server.py:140-145 ✓ | swap if/else ✓ | 5 | pending-verify |
VERDICT: both CORRECT find+fix; **code 5 < neat 7 (CODE WON)**. 411 is a STATIC CODE SMELL (inverted logic obviously wrong when read) -> strong code agent finds it directly; NEAT's runtime localization (recommendation) redundant, extra queries = overhead. NEAT no bug/misdirection (its incidents DID carry "Unmet validation constraint" -> correct) -> no issue filed.
PATTERN (401 tie, 411 code-win): NEAT draws/loses on SOURCE-FINDABLE faults even in PRAXIS. Fusion gap is in RUNTIME-DEPENDENT class only: 405-410 (missing timeout/retry around neo4j, an ABSENCE invisible from source) + 412 (latency). Those are the decisive test + need neo4j deployed / latency oracle.
