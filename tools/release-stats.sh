#!/bin/zsh
# How many copies of Kermo check for updates, and how each release was installed — from GitHub's download counts.
#   checks   latest.json: Kermo's daily update check (one per running Kermo a day, unless turned off), from the release after 2.1.1 on
#   /day     checks a day since the release came out
#   update   the .zip: Install and Relaunch
#   pkg      the .pkg: install.sh, or by hand
#   dmg      the .dmg: by hand
# Counts are per release (a new release starts at 0), include any download by hand, and GitHub updates them with a delay.
# Usage: tools/release-stats.sh [how many releases, 8]
# /day: checks go to the latest release only, so a release's days end where the next one begins. Drafts are left out.
gh api "repos/paliydmn/kermo/releases?per_page=${1:-8}" --jq '
  ["release", "published", "checks", "/day", "update", "pkg", "dmg"],
  (map(select(.draft or .prerelease | not)) | . as $all | range(length) as $i | $all[$i] as $r
    | def n(s): [$r.assets[] | select(.name | endswith(s)) | .download_count] | add // 0;
    ((((if $i == 0 then now else $all[$i-1].published_at | fromdateiso8601 end) - ($r.published_at | fromdateiso8601)) / 86400)
      | if . < 1 then 1 else . end) as $days
    | [$r.tag_name, $r.published_at[0:10], n("latest.json"), ((n("latest.json") / $days * 10 | round) / 10),
       n(".zip"), n(".pkg"), n(".dmg")])
  | @tsv' | column -t -s $'\t'
