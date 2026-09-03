# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Stack

Delegated: React + TypeScript + Vite. The S12 execution contract names `web/src/` and requires an embedded FiveM NUI, so this keeps the UI self-contained and buildable into the resource.

## Users

Players using NightShift in-game to find an available worker and request a booking without leaving the FiveM client.

## Product Purpose

NightShift provides a server-authoritative marketplace and booking flow for player and NPC workers. The NUI lets a client discover options, understand availability and travel expectations, then submit a booking request.

## Positioning

The interface is a thin, typed presentation layer over the Unified Booking Core: it may request a quote and confirm its server-issued ID, but never supplies authoritative prices, booking state, or settlement data.

## Operating Context

The surface is used as a focused in-game overlay. The user must scan a small marketplace list quickly, compare worker options, choose a meeting mode and allowed location, and confirm a short-lived quote.

## Capabilities and Constraints

- Marketplace results are paginated public cards, not full worker profiles.
- Server callbacks validate input and own all pricing, availability, and booking decisions.
- The browser uses typed NUI callbacks with request IDs and a local mock bridge for development.
- Adult-themed interaction remains non-graphic and abstract.
- The user explicitly requested Swiss design, shadcn components, and Impeccable-quality interface craft.

## Evidence on Hand

- Marketplace query service: `server/services/marketplace_query_service.lua`.
- Unified booking and pricing services: `server/services/booking_service.lua`, `server/services/pricing_service.lua`.
- S12 execution requirements: `C:/Users/Gnesh/Downloads/NightShift_IMPLEMENTATION_PLAN.md`.

## Product Principles

1. Server authority is visible in the flow: quotes and booking outcomes come from the server.
2. In-game decisions should be fast to scan and hard to misunderstand.
3. Public worker information stays minimal and privacy-preserving.
4. Error and pending states explain the next useful action.

## Accessibility & Inclusion

Keyboard navigation, focus visibility, reduced motion support, readable contrast, and mobile-safe controls are required.
