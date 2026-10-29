# Backfilling a missed-watch period

If you wore WHOOP while your Apple Watch was off, HealthDataBridge can attempt to fill missing Apple Health heart-rate samples and sleep stages afterward. You do not need to record a live Bluetooth session during that period.

## Import the missing data

1. Open the official WHOOP app and let the strap upload its recorded data. Confirm the missing period is visible there before starting the bridge.
2. Connect HealthDataBridge and configure sync as described in [Usage](USAGE.md). Grant the relevant Health read and write permissions. Existing visible sleep and heart-rate samples are needed for the app's read-visibility checks; these checks must not be bypassed by creating artificial samples.
3. For a recent gap, use **Sync now**. The initial sync requests seven days. Later heart-rate syncs revisit the last 24 hours as well as older unfinished progress, so data uploaded after an earlier run can be reconsidered. Sleep and configured recovery HRV have their existing seven-day revision windows.
4. If the gap is older than those windows, use **Options → Import an earlier period** and choose its start date. This imports the selected start through the fixed cutoff shown by the app; it is not an exact one-day selector. Resume pending imports using the existing resume action.
5. Inspect the result for errors, pending access or manual review. A successful empty response does not establish that WHOOP has finished uploading. If data is still absent, confirm it exists in WHOOP and retry the applicable period.

The heart-rate recheck may fetch four six-hour chunks on an ordinary run, rather than just the small interval since the previous checkpoint. It is bounded; data arriving more than 24 hours late may require an explicit historical import. Confirmed live checkpoints are not rewound while older chunks are rechecked.

The bridge preserves other apps' records and skips heart-rate buckets already covered by an external source. It writes with its own source identity; it does not impersonate Apple Watch. Sparse readings from another device do not necessarily cover every bucket, so a period can contain samples from multiple sources. The bridge does not synthesize missing heartbeats, daytime HRV or skin temperature.

## Check Apple Health, then the downstream app

In Apple Health, inspect **Heart Rate → Show All Data** for the missing dates and times. Confirm the imported source and timestamps, rather than relying only on a daily average. Check sleep stages separately if an overnight period was missing. Repeat the same import and confirm it does not add duplicate samples.

Then check the receiving app. Having a record in Apple Health establishes storage, not that every receiving app will select it or recompute a historical score.

### Bevel

Bevel documents importing metrics through Apple Health. In **Profile → Data Sources**, inspect the relevant heart-rate and sleep sources and ensure the bridge is not hidden. Keep the desired Apple Watch sources available as well. Reload data if needed, then inspect the missing period's heart-rate graph and Strain. Do not assume that a source-priority setting behaves identically in Apple Health and Bevel.

For a daytime gap when your overnight Apple Watch data is already present, heart-rate backfill is the first useful acceptance check: Bevel describes daily Strain as including both workout and non-workout heart rate. This is an integration test to perform, not a claim that this project has validated Bevel.

If the missing period includes sleep, assess Recovery separately. HealthDataBridge's optional HRV is WHOOP's nightly RMSSD value, not SDNN or a raw beat-to-beat series. Bevel's RMSSD documentation describes Apple Watch beat-to-beat measurements and native Recovery HRV from supported newer Apple Watches. It does not establish support for this bridge's WHOOP RMSSD records. A visible imported HRV value therefore does not certify a Recovery score, Stress history, or equivalence to wearing Apple Watch. Do not put RMSSD into an SDNN field to make a chart appear.

Relevant first-party documentation (checked 2026-10-29):

- [Bevel: How To Connect Devices](https://help.bevel.health/en/articles/10400449)
- [Bevel: Data Sources Troubleshooting](https://help.bevel.health/en/articles/11680065)
- [Bevel: How to Change Calculations](https://help.bevel.health/en/articles/10431233)
- [Bevel: Key Terms, including Strain](https://help.bevel.health/en/articles/11251073)
- [Bevel: Strain Troubleshooting](https://help.bevel.health/en/articles/11257921)
- [WHOOP API support: no continuous heart-rate data](https://developer.whoop.com/docs/developing/support/)

HealthDataBridge uses private WHOOP endpoints for historical heart rate. Availability of a period in the official app does not guarantee those endpoints will return it. No Bevel integration or personal-device acceptance is claimed by this guide.
