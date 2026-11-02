---
kind: routine
id: atrium/ship-log
revision: 1
title: Ship log
summary: The week's merged work as a short changelog draft, plus the numbers.
category: engineering
tags: [changelog, shipped, weekly, release-notes, github, posthog]
icon: ScrollText
target: director
mode: standing
schedule: { cron: "0 15 * * 5", tz: "{timezone}" }
scheduleLabel: Fri 15:00
params:
  - { key: repo, label: Repository, kind: text, help: "The GitHub repository, as owner/name." }
needs:
  - id: github
    label: GitHub
    why: read the week's merged pull requests and releases
    required: true
    anyOf: [{ preset: github }, { cli: gh }]
  - { preset: posthog, label: PostHog, why: add adoption numbers, required: false }
effects: [read, draft]
asksFirst: ["publishing release notes or posts"]
minAtrium: "0.351.0"
attribution: { author: atrium, license: CC0-1.0 }
---

## Prompt

Draft this week's ship log for {repo}: what merged, as a short changelog.

1. List the pull requests merged since your last ship log (or in the last seven days). Skip chores, dependency bumps, and reverts of things that never shipped.
2. Group them by what a user notices: New, Improved, Fixed. One plain line each, with the PR link. Use anything your playbook adds.
3. Put the numbers at the bottom: PRs merged, issues closed, releases cut, and adoption of the latest release if PostHog is connected.
4. Save it as a note and tell the owner in one line that it's ready. Never publish it, post it or cut a release.
5. A week with nothing merged gets one line, not a log.

If you can't reach GitHub, say so once, ask for access, and stop until the next pass.
