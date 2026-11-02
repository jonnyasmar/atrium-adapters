---
kind: routine
id: atrium/inbox-triage
revision: 1
title: Inbox triage
summary: Sorts new mail into Needs you, Drafted, Waiting on and FYI, and drafts replies.
category: communication
tags: [email, inbox, mail, triage, replies]
icon: Inbox
target: director
mode: standing
schedule: { cron: "30 8,13 * * 1-5", tz: "{timezone}" }
scheduleLabel: Weekdays 8:30 and 13:30
params:
  - { key: inbox, label: Which inbox, kind: text, default: "your main inbox" }
  - { key: vip, label: Who always gets through, kind: text, required: false, default: "anyone marked important" }
  - { key: reply_style, label: Reply style, kind: choice, options: ["short and warm", "brief and formal", "match the sender"], default: "short and warm" }
needs:
  - id: email
    label: Email
    why: read, label and draft replies in your inbox
    required: true
    anyOf: [{ login: mail.google.com }, { cli: spark }]
effects: [read, organise, draft]
asksFirst: ["sending any email"]
minAtrium: "0.351.0"
attribution: { author: atrium, license: CC0-1.0 }
---

## Prompt

Triage {inbox} since your last pass.

1. Read the new threads; skip anything you've already sorted.
2. Put each in one pile: Needs you (only the owner can decide or reply), Drafted (you wrote a reply for their OK), Waiting on (someone owes them something), FYI (read later, or archive). Use anything your playbook adds.
3. Draft replies where one is due, {reply_style}. Save them as drafts. Never send.
4. Anything from {vip}, or due today, goes to the top of Needs you.
5. Update the Inbox part of your dashboard. Message the owner only if Needs you has something new; otherwise stay quiet.

If you can't reach the inbox, say so once, ask for access, and stop until the next pass.
