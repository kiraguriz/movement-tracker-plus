# Live service UI evidence — 2026-11-01

Captured on the iPhone 18 Pro Max simulator running iOS 27.0. The first two captures used the deployed
proxy without the Coach stub; the landscape capture used local seeded data. All workout/profile data and
the meal illustration are synthetic. These screenshots establish service integration and rendered behavior,
not real-person counting or real-food estimation accuracy.

- [Set review](live-set-review.jpg): the on-device replay produced 10 reps and 1 partial; Muse returned
  advice citing specific reps. Session debrief was also exercised, as recorded in the UI report.
- [Meal photo review](live-meal-photo.jpg): Muse identified the illustration and explicitly noted its
  uncertainty. After USDA matching and confirmation, Eat showed two saved items totaling 176 kcal.
- [Today after scrolling in landscape](today-landscape-scrolled.png): synthetic workout metrics and the
  chart data region are visible above the tab accessory. History was opened successfully in the same check.
  This layout check used local seeded data and does not establish a live model response.

The images are unmodified copies of the UI tool captures. Test scope, failures and retests are recorded in
[the UI debug report](../ui-debug-report.md).
