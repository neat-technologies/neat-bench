# scenario_34 — Deployment/valkey-cart password auth added (TRACE-VISIBLE datastore-connection fault)
groundtruth: Deployment valkey-cart (+ new Secret valkey-credentials); symptom: cart FailedPrecondition "Wasn't able to connect to redis" (ValkeyCartStore.cs:101)
| arm | ssh cmds | verdict | note |
|-----|----------|---------|------|
| neat    | 5 | CORRECT | root-cause MISLED (blamed load-generator, red herring); recovered via `neat incidents service:cart` (redis error) -> valkey. Still < obscode. |
| obscode | 7 | CORRECT | pods->logs->valkey deploy->secret->cart env->source; ruled out flagd/netpol |
VERDICT: both correct; NEAT 5 vs obscode 7. **NEAT root-cause BUG confirmed**: over-attributes to load-generator on outbound datastore-connection failure. Fix -> neat ~3.
