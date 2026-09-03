# Client Mode

Client Mode is the customer-side booking flow exposed through the NUI gateway and client transport.

Supported meeting modes are COME_TO_ME, PICKUP, and MEET_THERE. The server validates the package, quote, worker, location, travel state, vehicle/entity evidence, appointment token, and ownership at every transition.

Typical sequence: list workers -> request quote -> confirm quote -> travel/spawn as required -> arrival confirmation -> session start -> session complete. Use the returned booking ID/token from the immediately preceding successful response. Client coordinates, prices, booking status, and settlement amounts are advisory only and ignored when authoritative data exists.

The NUI opens with the in-game nightshift_marketplace command and closes through the UI close action.
