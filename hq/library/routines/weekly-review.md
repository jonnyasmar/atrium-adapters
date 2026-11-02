---
kind: routine
id: atrium/weekly-review
revision: 1
title: Weekly review
summary: What got done, what slipped, and the three things that matter next week.
category: communication
tags: [review, weekly, planning, priorities, summary]
icon: CalendarCheck
target: director
mode: standing
schedule: { cron: "0 16 * * 5", tz: "{timezone}" }
scheduleLabel: Fri 16:00
params:
  - { key: goals, label: What matters most right now, kind: text, required: false, default: "" }
needs:
  - id: calendar
    label: Calendar
    why: see what's planned for next week
    required: false
    anyOf: [{ login: calendar.google.com }]
  - { preset: github, label: GitHub, why: work merged and issues closed this week, required: false }
  - { preset: linear, label: Linear, why: what closed and what slipped, required: false }
effects: [read, notify, draft]
minAtrium: "0.351.0"
attribution: { author: atrium, license: CC0-1.0 }
---

## Prompt

Write the owner's weekly review. At most 15 lines; skip any part with nothing in it. Use anything your playbook adds.

1. **Done:** what finished this week: merged work, closed issues, your staff's and routines' results. Outcomes, one line each.
2. **Slipped:** what was due or promised and didn't happen, with the reason in a few words if you know it. No blame.
3. **Next week:** the three things that matter most. Weigh them against the owner's goals: {goals} (if that's blank, use what your notebook says matters). Note what's already on the calendar for them.
4. **Loose ends:** commitments with no owner or no date, and anything worth dropping.

Post it as your weekly review and refresh your dashboard. Draft next week's three as reminders or tasks, and create them only when the owner says yes.

If you can't reach a source, review from the rest; say once what's missing, ask for access, and don't ask again until the owner answers.
