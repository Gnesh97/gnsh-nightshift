# NPC travel and entities

Travel is a logical server-owned plan and does not require a physical ped. It tracks origin/destination, ETA, monotonic progress, spawn threshold, arrival, return, timeout, and recovery states.

Physical NPCs are optional. Spawn authorization uses server-resolved model/location candidates, generation tokens, minimal state metadata, ownership checks, and an entity/network registry. Client-supplied model, coordinates, booking state, or handles cannot authorize a spawn or arrival.

Streaming is budgeted globally, per source, and per district. Leases expire unless renewed; deleted or invalid entities are treated as lost and cleaned up. Test logical travel first, then physical spawn/navigation/entity replacement in FiveM.
