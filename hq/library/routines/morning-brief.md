---
kind: routine
id: atrium/morning-brief
revision: 1
title: Morning brief
summary: Today's meetings, what needs you, what moved overnight, and what's at risk.
category: communication
tags: [brief, morning, daily, summary, calendar, agenda]
icon: Sunrise
target: director
mode: standing
schedule: { cron: "30 8 * * 1-5", tz: "{timezone}" }
scheduleLabel: Weekdays 8:30
params:
  - { key: topics, label: Topics you follow, kind: text, required: false, default: "" }
needs:
  - id: calendar
    label: Calendar
    why: list today's meetings
    required: false
    anyOf: [{ login: calendar.google.com }]
  - id: email
    label: Email
    why: spot mail that needs you
    required: false
    anyOf: [{ login: mail.google.com }, { cli: spark }]
  - { preset: github, label: GitHub, why: PRs and issues waiting on you, required: false }
  - { preset: linear, label: Linear, why: "what's due this week", required: false }
effects: [read, notify]
minAtrium: "0.351.0"
attribution: { author: atrium, license: CC0-1.0 }
---

## Prompt

Write the owner's morning brief. At most 12 lines; lead with what needs a decision. Skip any section with nothing in it. Use anything your playbook adds.

1. **Today:** meetings and deadlines (from the calendar, if you can reach one).
2. **Needs you:** what's waiting on the owner: your open questions, reports that came in overnight, mail that needs them, PRs or issues waiting on their review.
3. **Moved:** what your staff and routines finished since yesterday. Outcomes only, one line each.
4. **At risk:** a slipping commitment, a failing check, a bill due.
5. **Worth knowing:** {topics}. Two or three items with links; leave this out if no topics are set.

Post it as your briefing and refresh your dashboard. If nothing is due and nothing moved, say that in one line.

If you can't reach a source, brief from the rest; say once what's missing, ask for access, and don't ask again until the owner answers.
