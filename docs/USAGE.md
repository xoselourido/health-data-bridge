# Usage

## Connect and configure once

Connect your own WHOOP account. New installations open Configure sync after sign-in: authorize sleep, heart rate and optional compatible recovery HRV together, then Save and sync. The initial lookback is seven days for all three types. You can continue without HRV and enable it later in Options → Configure sync. Later runs use confirmed checkpoints and revision windows. Existing health coverage is checked before writing; unreadable/ambiguous visibility can stop a run rather than assume absence.

Existing installations go directly to their usual Sync now button. Their account, permissions, historical scope and confirmed progress are retained; the new setup does not replace them with a seven-day history. Opening/authorizing/cancelling settings does not disable HRV or discard its saved confirmations.

After initial setup, add the Sync WHOOP App Shortcut to your own personal automation if desired. The app has no autonomous background scheduler. Locked-device access can fail safely without advancing checkpoints.

Daily heart-rate sync also rechecks the last 24 hours for points uploaded to WHOOP after a previous sync. Older unfinished progress is still included. Existing samples are reconciled again, so a repeated run does not duplicate confirmed records or replace another app's samples. This bounded recheck does not guarantee that arbitrarily delayed cloud data has arrived; use the explicit historical import for older gaps.

For a day without Apple Watch, see [Backfilling a missed-watch period](BACKFILL.md), including downstream-app verification and Bevel limitations.

## Optional recovery HRV

A supporting iOS 27 device is required. Recovery **RMSSD in milliseconds** is distinct from the WHOOP recovery score (%) and Apple Health's SDNN type. The import does not convert RMSSD to SDNN.

1. Open Options → Configure sync (or use the initial setup).
2. Select recovery HRV alongside sleep and heart rate.
3. Authorize selected data in one HealthKit request.
4. Review native WHOOP export coexistence and the visible read-access status. Select an actually observed native exporter if applicable. Where access remains unknown, an explicit personal confirmation is required; do not confirm full access unless it is true.
5. Confirm the existing account binding if requested, then save. If WHOOP already exports RMSSD, continue with sleep and heart rate without enabling duplicate HRV imports.
6. Use the same Sync now button or existing Shortcut for all configured data. There is no separate daily HRV action.

## Import an earlier period

Open Options → Import an earlier period, select the start date and confirm. This is an explicit common history import for sleep, heart rate and configured HRV, separate from daily synchronization. Inspect progress, pending items and manual-review messages. Stop if necessary, then use Resume historical import. Confirmed sleep/heart-rate history windows and HRV cursors are retained across restarts; live checkpoints and Shortcuts are not reset or forced into this traversal. Existing wider HRV scope is retained and pending HRV work may include that earlier period.

The original WHOOP account session is reused. Recovery setup does not require a new login merely because this optional feature was added. An account mismatch blocks use of another account's progress. There is no archive-state selector for switching between accounts.

History windows are bounded and rate limiting is respected. An empty page is not taken as proof of absolute historical exhaustion. The UI reports completion of the indicated scope rather than claiming all provider history was verified.

If read permissions change, revisit authorization/configuration. A previous manual full-access confirmation cannot detect hidden later revocations. Limited historical visibility and uncertain native coexistence can leave records pending; do not assume an empty result means there are no existing records.
