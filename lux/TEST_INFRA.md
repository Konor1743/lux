# E2E Test Infra: YouTube Core API Integration

## Test Philosophy
- Opaque-box, requirement-driven.
- Full offline mock isolation using `Req.Test` and plug interception.
- Methodology: Category-Partition + Boundary Value Analysis (BVA) + Pairwise + Real-World Workload Testing.

## Feature Inventory
| # | Feature | Source (Requirement) | Tier 1 (Coverage) | Tier 2 (Boundary) | Tier 3 (Pairwise) | Tier 4 (Real-World) |
|---|---------|---------------------|:-----------------:|:-----------------:|:-----------------:|:-------------------:|
| 1 | OAuth 2.0 Flow & Token Refresh | ORIGINAL_REQUEST §R1 | ≥5 cases | ≥5 cases | ✓ | ✓ |
| 2 | YouTube API Client & Error Handling | ORIGINAL_REQUEST §R1, §R4 | ≥5 cases | ≥5 cases | ✓ | ✓ |
| 3 | Live Broadcast Lifecycle & Management | ORIGINAL_REQUEST §R2 | ≥5 cases | ≥5 cases | ✓ | ✓ |
| 4 | Live Stream Ingestion & Binding | ORIGINAL_REQUEST §R2 | ≥5 cases | ≥5 cases | ✓ | ✓ |
| 5 | Live Chat Reading & Poller Pagination | ORIGINAL_REQUEST §R3 | ≥5 cases | ≥5 cases | ✓ | ✓ |
| 6 | Quota (403) & Rate Limit (429) Handling | ORIGINAL_REQUEST §R4 | ≥5 cases | ≥5 cases | ✓ | ✓ |

## Test Architecture
- Test Runner: `mix test` / `mix test.unit`
- Mock Framework: `Req.Test` stubs and plugs (`UnitAPICase` or custom test plug)
- Directories: `test/unit/lux/integrations/youtube/`, `test/e2e/`
- Coverage Tool: `mix coveralls` (ensuring >90% coverage for all new YouTube modules)

## Pass / Fail Criteria
- 100% test cases pass.
- 0 warnings under `mix compile --warnings-as-errors`.
- YouTube module test coverage >90%.
- Forensic Auditor verdict CLEAN.
