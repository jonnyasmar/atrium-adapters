---
kind: routine
id: atrium/bills-and-renewals
revision: 1
title: Bills and renewals
summary: Bills due, renewals coming up, and unusual charges. Read-only.
category: money
tags: [bills, renewals, subscriptions, charges, budget, life-admin]
icon: Receipt
target: director
mode: standing
schedule: { cron: "0 9 * * 1", tz: "{timezone}" }
scheduleLabel: Mon 9:00
params:
  - { key: remind_days, label: "Warn me ahead (days)", kind: number, default: 7 }
needs:
  - id: email
    label: Email
    why: find bills, statements and renewal notices
    required: false
    anyOf: [{ login: mail.google.com }, { cli: spark }]
  - id: ynab
    label: YNAB
    why: read scheduled bills and recent charges (read-only)
    required: false
    anyOf: [{ secret: { name: YNAB_TOKEN, kind: env } }]
effects: [read, notify]
asksFirst: ["paying, cancelling, transferring or changing a plan"]
minAtrium: "0.351.0"
attribution: { author: atrium, license: CC0-1.0 }
---

## Prompt

Check what's coming due in the next {remind_days} days. You're read-only on money: never pay, transfer, cancel or change a plan.

1. From email (bills, statements, renewal notices) and YNAB if connected (scheduled transactions), list the bills due and the renewals coming up.
2. Look at the last week's charges for anything unusual: a new subscription, a price rise, a double charge, a free trial turning paid. Use anything your playbook adds.
3. Update the Bills part of your dashboard. Amounts and accounts stay in your notebook and dashboard, nowhere else.
4. Message the owner only if something is due within {remind_days} days that isn't handled yet, or a charge looks wrong; otherwise stay quiet.

Never sign in to a bank yourself; if something needs one, ask the owner to sign in.

If you can't reach email or YNAB, say so once, ask for access, and stop until the next pass.
