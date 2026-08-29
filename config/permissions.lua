NightShift = NightShift or {}

-- Permission definitions are server policy. They are never accepted from a
-- client payload; the permission service evaluates them against server-side
-- framework identity, ACE state, and optional trusted hooks.
NightShift.PermissionConfig = NightShift.PermissionConfig or {
    permissions = {
        ['admin.manage'] = { ace = 'nightshift.admin', jobs = { admin = 0 } },
        ['agency.manage'] = { ace = 'nightshift.agency', jobs = { agency = 0 } },
        ['venue.manage'] = { ace = 'nightshift.venue', jobs = { venue = 0 } },
        ['worker.profile.view'] = { jobs = { worker = 0 } },
        ['worker.profile.update'] = { jobs = { worker = 0 } },
        ['booking.manage'] = { jobs = { worker = 0, agency = 0, venue = 0 } },
        ['booking.override'] = { ace = 'nightshift.admin', jobs = { admin = 0 } }
    }
}

NightShift.PermissionKeys = NightShift.PermissionKeys or NightShift.PermissionConfig.permissions
NightShift.Permissions = NightShift.Permissions or NightShift.PermissionConfig
