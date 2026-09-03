# Abuse Matrix (S27 / NS-274)

| Attempt | Required server boundary | Expected result |
| --- | --- | --- |
| Fake completion/arrival | booking state, owner, location and appointment token | typed state/ownership/proximity error |
| Client-supplied price | authoritative catalog/quote resolver | client value ignored or QUOTE_INVALID |
| Client-supplied refund | refund eligibility and settlement state | REFUND_NOT_ELIGIBLE |
| Settlement replay | one-time settlement/idempotency key | idempotent result; no second payment |
| Deposit replay | deposit state and idempotency | no second hold/capture |
| Arbitrary NPC worker | availability lock and marketplace allowlist | worker unavailable/busy |
| Arbitrary location | typed location resolver/provider | INVALID_LOCATION_REFERENCE |
| Review without eligibility | settled booking and actor binding | REVIEW_NOT_ELIGIBLE |
| Huge/malformed payload | NUI schema and bounded DTO validators | NUI_REQUEST_INVALID / typed validation error |
| Unauthorized admin/agency operation | centralized permission service | permission denial with no mutation |
| Request spam | source/method token bucket | RATE_LIMITED, bounded retry hint |
| Action-token replay or substitution | actor/booking/action/TTL binding | ACTION_TOKEN_REPLAY or typed mismatch |

No abuse case is allowed to mutate money, booking ownership, or terminal
state after a failed boundary check.
