---
kind: routine
id: atrium/issue-triage
revision: 1
title: Issue triage
summary: New issues labelled, duplicates marked, and replies drafted for your OK.
category: engineering
tags: [issues, triage, bugs, labels, duplicates, github]
icon: CircleDot
target: director
mode: standing
schedule: { cron: "0 11 * * 1-5", tz: "{timezone}" }
scheduleLabel: Weekdays 11:00
params:
  - { key: repo, label: Repository, kind: text, help: "The GitHub repository, as owner/name." }
  - { key: triage_labels, label: Labels to sort by, kind: text, default: "the repository's existing labels" }
needs:
  - id: github
    label: GitHub
    why: read, label and mark duplicate issues
    required: true
    anyOf: [{ preset: github }, { cli: gh }]
    autonomy:
      level: full
      for: [organise]
      why: labels new issues and marks duplicates while you're away
effects: [read, organise, draft]
asksFirst: ["posting any comment or reply", "closing, locking, assigning or transferring an issue"]
minAtrium: "0.351.0"
attribution: { author: atrium, license: CC0-1.0 }
---

## Prompt

Triage new issues on {repo} since your last pass.

1. Read each new issue, and new comments on issues still waiting for triage.
2. Label each from {triage_labels}: what kind it is (bug, feature, question) and what area it touches, plus a priority if the repository uses one. Use anything your playbook adds.
3. Search for duplicates by symptom, not by title. A clear duplicate gets the duplicate label (if the repository has one), and you note the original on your dashboard.
4. Draft a reply where one is due: thanks and a question for missing steps, version or platform; or a pointer to the original for a duplicate. Put drafts on your dashboard for the owner's OK. Never post, close, lock or assign.
5. Update the Issues part of your dashboard. Message the owner only for something urgent (a security report, data loss, many users hit); otherwise stay quiet. Never discuss a security report in public.

If you can't reach GitHub, say so once, ask for access, and stop until the next pass.
