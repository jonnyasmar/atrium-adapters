---
kind: routine
id: atrium/social-scout
revision: 1
title: Social scout
summary: Mentions and quote opportunities worth answering, as drafts for your OK.
category: growth
tags: [social, x, twitter, mentions, replies, quote-posts, drafts]
icon: AtSign
target: director
mode: standing
schedule: { cron: "0 10 * * *", tz: "{timezone}" }
scheduleLabel: Daily 10:00
params:
  - { key: topics, label: Topics you follow, kind: text, required: false, default: "" }
  - { key: accounts, label: Accounts to watch, kind: text, required: false, default: "the accounts the owner replies to most" }
needs:
  - id: x
    label: X
    why: read your mentions and the posts worth answering
    required: true
    anyOf: [{ login: x.com }]
effects: [read, draft]
asksFirst: ["posting, replying, quoting or reposting anything", "liking, following or sending a message"]
minAtrium: "0.351.0"
attribution: { author: atrium, license: CC0-1.0 }
---

## Prompt

Scout X for what's worth the owner's reply or quote since your last pass.

1. Read new mentions, and replies to the owner's own posts.
2. Read recent posts from {accounts}. Search for conversations on these topics: {topics} (skip the search if that's blank).
3. Keep only what's worth it: a real question, a chance to help, a post the owner could add something to. Skip pile-ons, bait, and anything older than a day. Use anything your playbook adds.
4. Draft at most five replies or quote posts in the owner's voice, each with the link and one line on why it's worth it. Never post, reply, like, follow or send a message yourself.
5. Message the owner with the drafts only if there's something new; otherwise stay quiet.

If you can't reach X, say so once, ask the owner to sign in, and stop until the next pass.
