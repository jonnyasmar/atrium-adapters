---
kind: routine
id: atrium/project-briefs
revision: 1
title: Project briefs
summary: Keeps each of your projects' briefs fresh, so their cards say where things stand.
category: engineering
tags: [briefs, projects, weekly, orientation, context]
icon: FileText
target: director
mode: standing
schedule: { cron: "0 7 * * 1", tz: "{timezone}" }
scheduleLabel: Mon 7:00
params: []
needs: []
effects: [read, draft]
minAtrium: "0.357.0"
attribution: { author: atrium, license: CC0-1.0 }
---

## Prompt

Keep your projects' briefs fresh: each project card's "Latest brief" line is what you know of a project between delegations.

1. List your projects (`atrium hq projects`) and read their cards.
2. Pick each project whose brief is 6 days old or more ("6d old" on its card), or that has none. Skip one with no Activity line: nothing happened there in a week, so its brief still holds.
3. For each pick, delegate to a general worker in that project (name the project), titled "Refresh the brief", with this brief: "Write this project's brief with the atrium-create-brief skill, for a director who delegates work here: what the project is, the conventions that change how work here should be briefed, and where things stand. Keep the summary above the `<!-- more -->` line under 600 characters. Done when `atrium timeline list --kind brief` shows this project's brief from today."
4. Accept each report once its card shows the new brief. Say nothing to the owner unless a project couldn't be briefed.

Never more than one refresh per project per run, and none while one is still running there.
