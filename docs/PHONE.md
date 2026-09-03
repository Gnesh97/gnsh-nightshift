# Phone integration

Phone integrations are optional. An adapter may implement availability/capabilities, app registration, push notification, and open-app routing. The registry supports generic, LB Phone, QS, QB, and YSeries integration modules when the corresponding resource contract is present.

Missing, stopped, unsupported, or throwing providers return a typed skipped/unavailable result. NightShift does not discover arbitrary phone resources or require phone state for booking authority. Keep notification payloads bounded and privacy-safe.
