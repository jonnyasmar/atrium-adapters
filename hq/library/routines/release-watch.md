---
kind: routine
id: atrium/release-watch
revision: 1
title: Release watch
summary: After a release, watches for error spikes, failed deploys and adoption. Ends once it's quiet.
category: engineering
tags: [release, deploy, errors, adoption, monitoring, github, sentry, posthog]
icon: Activity
target: director
mode: on-demand
schedule: { cron: "*/30 * * * *", tz: "{timezone}" }
scheduleLabel: Every 30 minutes until it's quiet
doneWhen: "Nothing new has gone wrong with the release for {watch_hours} hours."
params:
  - { key: repo, label: Repository, kind: text, help: "The GitHub repository, as owner/name." }
  - { key: release, label: Which release, kind: text, default: "the newest release" }
  - { key: watch_hours, label: "Watch for (hours)", kind: number, default: 24 }
needs:
  - id: github
    label: GitHub
    why: read the release, its deploys and its changes
    required: true
    anyOf: [{ preset: github }, { cli: gh }]
  - { preset: sentry, label: Sentry, why: spot error spikes after the release, required: false }
  - { preset: posthog, label: PostHog, why: see adoption after the release, required: false }
effects: [read, notify]
asksFirst: ["rolling back or re-running a deploy"]
minAtrium: "0.351.0"
attribution: { author: atrium, license: CC0-1.0 }
---

## Prompt

Watch {release} of {repo} until it has been quiet for {watch_hours} hours.

1. On the first pass, note the version and when it went out.
2. Check what changed since your last pass: new errors or a jump in the error rate (Sentry, if connected), failed deploys or failed checks on the release commit (GitHub), and adoption (PostHog, if connected).
3. Compare with the previous release, not with zero. Use anything your playbook adds.
4. Something new and real? Message the owner: the user-visible symptom, the suspect change (PR or commit), and what you'd do. Never roll back, re-run a deploy or change anything yourself.
5. Nothing new? Stay quiet. Once it has been quiet for {watch_hours} hours, post one line that the watch is over, and end this routine.

If you can't reach GitHub, say so once, ask for access, and stop until the next pass.
