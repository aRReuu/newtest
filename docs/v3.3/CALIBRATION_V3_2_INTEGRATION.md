# Impress V3.2 — calibration calibration uniting operations and integration authority

> Current development authority: open warehouseaRReuu/Impress-iphone-public-build / feature/impress-v3-r04-2-buildI don't know. Originalfeature/impress-calibration-v01Source: HEAD c16c4a605c5b6018861ff1691d6e6abba0d8901. This article does not give permission to private warehouses to write.

## 1. Product boundaries and structures
Impress is a tool for low-intensity personal growth: structured cognitive consolidation through flash cards, active memory and FSRS-6; and self-observation and calibration through minimal behavioural indicators. It is not a psychological diagnostic tool, a clinical health evaluation, an infinity cumulation game, or a complete task manager. Emotions may interact with sleep, exercise, diet, and it is not possible to infer cause and effect from trends in the instrument.
Three primary-level Tab (sequence fixed): flash cards, calibration, settings. The Note is not a Level 1 Tab, but a visible stand-alone text button on the right side of the flashcard ' s first page 's navigation column, separate from the card set; click on the old Obsidian Vault only read notes controller and return to remain in the flashcard ' s navigator. School entrance isImCalibrationVC/ImpressCalibrationViewController.swift;sight re-use ImpressV3Appearance, UIKit Dynamic Type, systemLight/Dark, the chart is tapeX/Y Week of Scale/Month/Year 2D couponI don't know. There are flashcards four-way slides, FSRS status, Obsidian Vault read-only entrances and settings that cannot be returned. Setup Add AppSystem/Light/Dark Triple and Chinese/Chinese/English Language Options;interface case and appearance token centrally configured. The change only has an impact and does not modify historical calibration scores, target snapshots, emotions or review events.

## 2. Five indicators and completion criteria
| Indicators| Records| Score|
| --- | --- | --- |
| Good morning.| +1 Completed, 1 Unfinished, 0Plan rest./Not applicableUnknown not assessed| Yes.|
| Sports| Ibid.| Yes.|
| Diet| Ibid.| Yes.|
| Emotion.| 1-5 Grade or explicitly Skip| Yes|
| Custom| The fifth behaviour set by the user;+1/-1/0/Unknown | Yes.|

The four standards of behaviour are user-enabled texts; emotions are only of value and are not subtracted by low points. The four acts must be clearly dealt with and the emotions recorded or jumped before the date is deemed to have been completed. The non-assessment does not automatically convert to incomplete; planned rest is not a punishment. Four exemptions with no additional points could be considered completed on that date, but the value is still not available (nil).

## 3. Unique authority for manual correction and rating
Extra +1 per day up to one, 1 up to one; save with a clear reason (up to 120 words) that can be modified and cleared. It is only intended for unplanned and does not take into account the existence of four separate acts. Semantic repetition must be confirmed by the user ' s judgement: the code prevents formal repetition through a fixed, independent eventKey and a quantitative limitation, but it does not automatically understand whether the two natural language acts are identical in substance.
Net daily score = number of completed - clearly uncompleted + additional points - additional points down. Do not publish values when unknown. Source authority onlyPackages/ImpressReviewCore/Sources/ImpressReviewCore/CalibrationScoreCore.swiftandCalibrationCheckInCore.swift; replicating another scorer at the UIKit, notification or permanence layer is prohibited. The FRSS-6 refresher rating is a completely different business and is not merged with the calibration.

## 4. Time series and comparability
X Could not close temporary folder: %s/Time zone.yyyy-MM-dd civilian dates cannot be grouped directly by UTC time stamp. A weekly view displays the last 7 calendar days, the latest 30 calendar days, and the annual view shows the average of 12 months** of net points for completed days**; no infinite points are used. The supporting trend is the average of valid scores in the previous seven calendar days, with the missing date and the uncompleted date remaining out of line and not filling in 0. The annual viewer controller draws another 3-month average guide, which should not pretend to be the 7-day moving average.
Changes in the number of behaviours, standards or mission difficulties reduce the comparability of the original net score over time. Absolute net scores should not be promoted as a scientific measure of overall growth, emotion or health.

## 5. Target and history snapshot
CaliberationGoals (the actual type of CaliberationGoals) saves four current standards; Caliberation DayCheckIn.goalsSnapshot saves daily historical standards. ** Indicators of change only for uncompleted changes in target for the same day**Restore Unknown/To be evaluated, without touching other identified indicators. The target snapshot of the completed dates remains unchanged.Over the Sun/Time zone changes on siteThe civil date of Calendar.current is attributed to a date string rather than GMT seconds; the date drifting and DST in the time zone should still be verified.

## 6. Local Data & Permission Border
- flashcard:Documents/ImpressV3/ReviewV3.sqlite（WCDB/FSRS-6;old ipressdata.db does not participate in start-up).
- Understanding history:Support/ImpressV3/LearningEntry-v1.json。
- Editable hints: ImpressV3LocalPromptLibraryV1 in UserDefaults Archiveprompts.json。
- Calibrationator: ApplicationSupport/ImpressCalibration/checkins-v1.json, Version 1, atom writing, decoded after reading; storage adaptor is ImpressCalibrationLocalStore actor.
- Obsidian Vault: The external Files Projecter authorized directory is the original document authority; production is locked and does not belong to the calibration, flashcard database or automated backup.
Project/The test must not be submitted to any truth.Checkins, databases, keys, certificates, Vault originals or private images; only synthetic test kits are stored in warehouses.

## 7. Single system notification commission
UNuser NotificationCenter Delegate is managed only by ImpressV3 NotificationCoordinator; calibration via ImpressCalibrationReminderCordonator Schedule, namespace impress.calibration.v1., independent of FSRS notification. The user's active authorization is required for defaulting on a local 20:00 and 22:00 per day for a non-repeated notification for the next 14 days; the FSRS notification quota is maintained and no permanent reminder is committed.
The calibration page itself shows an unassessed number. The remaining calibration notice of the day (retain future dates) is cancelled when five days of the day are completed; only the reference space is cancelled when the user closes. Notification click to direct the existing calibration to Tab by sharing ImpressCalibration NotificationRouteInbox. Permission denial, system focus mode, iOS backstage restriction and system notification of removable features must be properly communicated.

## 8. V3 Unified backup and recovery
Original R04.2 ZIP V1 with ReviewV3.sqlite,LearningEntry-v1.json、prompts.jsonwithmanifest.jsonI don't know. V3.2 ZIP V2 Addcheckins-v1.json, decoded using ZIP supported languages, CRC32, SHA-256, SQLite integration check and calibration of JSON. V1 Upon resumption** retention of calibration history of existing equipment** without silence. V2 The number of days to preview a card, review history, understand history and calibration before it is restored must be confirmed by the user; a quick roll-back copy of the photo, a suspense package and its replacement by the next cold start, failed to do its best to restore SQLite, hints, understanding history and calibration.
The backup is only provided by V3 BackupCordinator, and the calibration does not create iCloud or network synchronization operations. Calibration files mark V3 data changes after landing on the disk and decoding; iClaud Drive only tries to copy folders explicitly authorized by the user, and the successful writing by the file provider is not equal to the completion of the server sync. ** Current ZIP does not have a password **, even if availableSHA/CRCNor is completeness authentication confidential; the document should not be considered as end-to-end encrypted information.

## 9. Test, CI and acceptance.
CalibrationScoreCorestes, CalibrationCheckInCareTests, covering five closed doors, emotional skips, rest, extra points, historical snapshots,Week/Month/Year, Civil Days and Warning Plans. ImpressCalibrationIntegrationites covering three levels of Tab, route and temporary JSON durability; RevewWCDBRepositoryitesV1/V2Archiving and calibration of records.
Historically reversible R04.2 Baseline: Commit e9eb5e92679907ab95ac6aff615d5a6719b69eb46, correspondinghttps://github.com/aRReuu/Impress-iphone-public-build/actions/runs/39054675238：78/78UIKit XCTest passed, but the operation was earlier than V3.2 combined. **V3.2 The complete CI and the physical iPhone 13 of the final HEAD are pending reacceptance**; the old CI cannot be cited as a new version of the PASS.

## 10. Follow-up changes, open sources and door-to-door prohibitions
Current Publicfeature/impress-v3-r04-2-buildIt is the only authority that can be modified; it does not modify the public main, private warehouse or calibration branch. Independent maintenance of calibration purity Core, sole LocalStore, sole BackupCoordinator and existing notification commission; no duplication of operational level.
Release block: originalicon_1024.pngNot yet provided by the authorized source; substitution is prohibited. Unsigned, using the seven original iPhone Icon test IPA can only be listed as INCOMPLETE; a genuine iPhone 13 device authentication notice, iCloud authorization, restoration and UI is required before official release can be approved.
