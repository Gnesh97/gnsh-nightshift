# S26 Recovery

NightShift now exposes a bounded recovery classifier and startup observation
job. The classifier makes restart state explicit:

| Booking state | Policy |
| --- | --- |
| SCHEDULED | Preserve for the scheduling job |
| RESERVED, TRAVELLING, ACTIVE | Interrupt-and-release candidate |
| ARRIVED | Preserve for the no-show window |
| COMPLETED | Settlement retry candidate |

The startup job is observation-only by default. It scans a finite page window
before the resource becomes ready and reports preserved, pending, and failed
counts without changing bookings or money. The development commands are
console-only:

    /nightshift_s26_recovery
    /nightshift_s26_recovery_status

Applying an interruption or financial retry is intentionally a separate,
operator-reviewed action. recovery.apply defaults to false; the resource does
not enable that path through server.cfg.
