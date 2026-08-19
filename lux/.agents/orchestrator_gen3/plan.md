# Orchestrator Gen 3 Plan: YouTube Core API Integration (Milestones 3-5)

## Overview
Continuing the greenfield implementation of the YouTube Core API integration and Live Streaming capabilities for the Lux framework (Issue #68).
Milestones 1 & 2 are complete. Milestones 3, 4, and 5 will be executed sequentially using the full Teamwork verification cycle.

## Milestone 3: Live Chat Reading & Poller
- Scope:
  - `Lux.Integrations.YouTube.LiveChat` (list messages, insert message, message parsing, author details)
  - `Lux.Integrations.YouTube.LiveChat.Poller` (GenServer / poller stream, pagination with `nextPageToken`, respecting `pollingIntervalMillis`, backoff on empty/error, signal emission / callback handling)
  - Unit & Poller simulation tests (`test/unit/lux/integrations/youtube/live_chat_test.exs`, `test/unit/lux/integrations/youtube/poller_test.exs`)
- Steps:
  1. Dispatch 3 Explorers (Architecture & API analysis, GenServer Poller design & backpressure, test isolation & pagination simulation)
  2. Synthesize Explorer recommendations
  3. Dispatch 1 Worker to implement `LiveChat` & `Poller` modules and comprehensive unit tests
  4. Dispatch 2 Reviewers (Correctness review & GenServer lifecycle / error handling review)
  5. Dispatch 2 Challengers (Pagination stress testing & Poller resilience challenge)
  6. Dispatch 1 Forensic Auditor for integrity check
  7. Gate Evaluation (100% pass, 0 warnings, >90% coverage, clean audit)

## Milestone 4: Resiliency, Quota/Rate Limits & High-Level Lenses/Prisms
- Scope:
  - `Lux.Lenses.YouTube.*` (`ListBroadcasts`, `GetChatMessages`, `GetStream`)
  - `Lux.Prisms.YouTube.*` (`CreateBroadcast`, `SendChatMessage`)
  - Comprehensive resiliency mapping, error types, retry backoff
- Steps:
  1. Dispatch 3 Explorers
  2. Dispatch 1 Worker
  3. Dispatch 2 Reviewers
  4. Dispatch 2 Challengers
  5. Dispatch 1 Forensic Auditor
  6. Gate Evaluation

## Milestone 5: Full E2E Test Suite (Tiers 1-4) & Adversarial Hardening (Tier 5)
- Scope:
  - End-to-end integration test suite covering all 6 features (Tiers 1-4)
  - Tier 5 white-box adversarial stress testing
  - Final coverage audit (>90%) and zero compiler warnings verification (`mix compile --warnings-as-errors`)
- Steps:
  1. Dispatch Worker for E2E suite
  2. Dispatch 2 Challengers for adversarial hardening
  3. Dispatch 2 Reviewers
  4. Dispatch Final Forensic Auditor
  5. Gate Evaluation
  6. Victory report to Sentinel (`f9c7b69e-1f58-4012-8bad-c6ddcc780de3`)
