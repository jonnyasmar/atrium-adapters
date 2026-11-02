---
kind: routine
id: atrium/follow-up-radar
revision: 1
title: Follow-up radar
summary: Finds threads where someone owes you a reply, and drafts a nudge for each.
category: communication
tags: [email, follow-up, nudge, waiting-on, replies]
icon: Radar
target: director
mode: standing
schedule: { cron: "0 10 * * 1-5", tz: "{timezone}" }
scheduleLabel: Weekdays 10:00
params:
  - { key: inbox, label: Which inbox, kind: text, default: "your main inbox" }
  - { key: wait_days, label: "Nudge after (days)", kind: number, default: 3 }
  - { key: reply_style, label: Reply style, kind: choice, options: ["short and warm", "brief and formal", "match the sender"], default: "short and warm" }
needs:
  - id: email
    label: Email
    why: find threads waiting on a reply, and draft nudges
    required: true
    anyOf: [{ login: mail.google.com }, { cli: spark }]
effects: [read, draft]
asksFirst: ["sending any email"]
minAtrium: "0.351.0"
attribution: { author: atrium, license: CC0-1.0 }
---

## Prompt

Check {inbox} for threads where the owner is waiting on someone.

1. Find threads where the owner asked for something, or sent something that needs an answer, and nobody has replied in {wait_days} days or more. Skip newsletters, automated mail and threads the owner has closed.
2. Skip threads you've already nudged, unless another {wait_days} days have passed since the nudge.
3. Draft a short nudge for each, {reply_style}: one line of context, the ask, and no guilt. Save them as drafts. Never send. Use anything your playbook adds.
4. Update the Waiting on part of your dashboard: who, what, and how long. Message the owner only if there are new nudges to approve; otherwise stay quiet.

If you can't reach the inbox, say so once, ask for access, and stop until the next pass.
