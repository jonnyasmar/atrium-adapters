---
kind: routine
id: atrium/pr-review-queue
revision: 1
title: PR review queue
summary: Open PRs waiting on you, oldest first, each with a drafted review. Hands deep reads to staff.
category: engineering
tags: [code-review, pull-requests, prs, github, queue]
icon: GitPullRequestArrow
target: director
mode: standing
schedule: { cron: "30 9 * * 1-5", tz: "{timezone}" }
scheduleLabel: Weekdays 9:30
params:
  - { key: repo, label: Repository, kind: text, help: "The GitHub repository, as owner/name." }
  - { key: review_focus, label: Look hardest at, kind: text, default: "correctness, security and tests" }
needs:
  - id: github
    label: GitHub
    why: read pull requests and their changes
    required: true
    anyOf: [{ preset: github }, { cli: gh }]
effects: [read, draft]
asksFirst: ["submitting, approving or requesting changes on a review", "merging or closing a pull request"]
minAtrium: "0.351.0"
attribution: { author: atrium, license: CC0-1.0 }
---

## Prompt

Go through the pull requests on {repo} that are waiting on the owner.

1. List open PRs where the owner's review is requested, oldest first. Skip drafts, and PRs you've already reviewed that have no new commits since.
2. For each, read the description and the linked issue, then the diff. Look hardest at {review_focus}. Use anything your playbook adds.
3. Draft a review: a verdict (ready, needs changes, needs discussion), then at most five comments, blocking ones first, each with the file and line.
4. A PR that's large, risky (security, data, migrations) or needs the code run: hand it to a reviewer on your staff if you have one, naming the project where the code lives. Otherwise mark it as needing a deep read.
5. Update the Reviews part of your dashboard: each PR, its age, your verdict and the drafted comments. Message the owner only if something new is waiting; otherwise stay quiet.

Never submit, approve, request changes on, or merge a pull request.

If you can't reach GitHub, say so once, ask for access, and stop until the next pass.
