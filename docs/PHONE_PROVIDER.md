# Phone provider contract

NightShift treats phone integrations as optional. A phone resource can register an adapter with NightShift.Phone.ProviderRegistry without becoming a core dependency.

An adapter may expose isAvailable(), getCapabilities(), registerApp(definition), pushNotification(playerSource, payload), and openApp(playerSource, route, context).

The registry detects capabilities, lists safe snapshots, and returns a successful skipped result when no provider exists, the provider is unavailable, an operation is unsupported, or an adapter throws. It never discovers or requires a particular phone resource.
