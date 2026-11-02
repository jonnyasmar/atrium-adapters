---
kind: routine
id: atrium/price-watch
revision: 1
title: Price watch
summary: Checks the prices on your watch list and tells you about real drops. Buys nothing.
category: life
tags: [prices, deals, shopping, watch-list, gifts]
icon: TrendingDown
target: director
mode: standing
schedule: { cron: "0 9 * * *", tz: "{timezone}" }
scheduleLabel: Daily 9:00
params:
  - { key: drop_pct, label: "Tell me at a drop of (%)", kind: number, default: 10 }
effects: [read, notify]
asksFirst: ["buying anything, or adding it to a cart"]
minAtrium: "0.351.0"
attribution: { author: atrium, license: CC0-1.0 }
---

## Prompt

Check the prices on the owner's watch list (the Watch list part of your dashboard). If the list is empty, stay quiet.

1. For each item, open its page and note today's price, whether it's in stock, and any coupon shown on the page.
2. Compare with the price when it was added and the lowest you've seen.
3. A drop of {drop_pct}% or more, or a price at or under the owner's target: message the owner with the item, the old and new price, and the link. Check the price history first; a "sale" is often the usual price. Use anything your playbook adds.
4. Update the watch list. An item the owner has bought, or no longer wants, comes off it.
5. Never buy, add to a cart, or sign up for anything in the owner's name. Nothing new? Stay quiet.

If an item's page won't load or hides the price, note it on the list and try again on the next pass. If it fails three passes running, say so once and ask the owner whether to keep watching it.
