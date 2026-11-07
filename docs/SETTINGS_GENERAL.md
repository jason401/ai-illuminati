# Settings → General: one layout for AI Face, AI Illuminati and Cats in Menubar

The three apps share this layout so the General tab looks and reads the same in each.
Change it here first, then in each app.

## Cards, in this order

1. **App**
   - Open at login — switch.
   - No language row. Each app follows the macOS language (System Settings → General →
     Language & Region → Applications can pick one per app). Apps with Korean list `en` and `ko`
     in `CFBundleLocalizations` and ship `en.lproj` / `ko.lproj`.
2. **Updates**
   - Check automatically — switch only.
   - Channel — Stable / Beta (main, for testing).
   - New version — "Check Now" while nothing is found; the blue "Update Now" in the same place
     once a new version is found.
   - While Update Now runs, the New version row shows a step bar instead of the button: one
     segment per update step (each app names its own), the step with time elapsed and, from the
     last update's step times, time left, and the last line of output ("no output for 45s" once
     it goes quiet). Yellow while waiting, red at the step that failed. The menu bar menu shows
     the same step line.
   - A small note below: the Beta warning, what the last check found, and when.
3. **Folders**
   - One row, "Open": App data → buttons only this app has (AI Illuminati: Accounts,
     Cats: Logs) → App (selects the app in Finder).
4. **About**
   - Version — `0.3.0 Beta (3a3588d)`: version, "Beta" when built from main, short revision.
     The build number and full revision show on hover.
   - Optional: one line only this app needs (Cats: its network-use note).
   - Licenses — "Show" opens the bundled `THIRD_PARTY_NOTICES.md`.

## Wording

- Buttons: "Check Now", "Update Now", "Show". Korean: 지금 확인, 지금 업데이트, 보기.
- Card titles: App / Updates / Folders / About (앱 / 업데이트 / 폴더 / 정보).
- Rows are separated by a divider. Row names fit one line (AI Illuminati: a 118 pt name column).
