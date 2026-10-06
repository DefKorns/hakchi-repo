#!/usr/bin/env bash
# Builds the hakchi2-CE repository into site/ from the latest GitHub release
# of every entry in sources.txt. Needs gh (authenticated), curl and tar.
set -euo pipefail

cd "$(dirname "$0")"
OUT=site
SITE_URL=${SITE_URL:-https://defkorns.github.io/hakchi-repo/}
REPO_DIR=$OUT/.repo
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

rm -rf "$OUT"
mkdir -p "$REPO_DIR"
touch "$OUT/.nojekyll"
: > "$REPO_DIR/list"
categories=()
declare -A cat_md cat_rows

html_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
trim() { local s=$1; s=${s#"${s%%[![:space:]]*}"}; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

while IFS='|' read -r repo name pattern channel category description; do
  repo=$(trim "$repo")
  case "$repo" in '' | \#*) continue ;; esac
  name=$(trim "$name")
  pattern=$(trim "$pattern")
  channel=$(trim "${channel:-stable}")
  category=$(trim "$category")
  description=$(trim "${description%$'\r'}")

  stable_only='| select(.prerelease | not)'
  [ "$channel" = pre ] && stable_only=''

  release=$(PATTERN="$pattern" gh api "repos/$repo/releases?per_page=30" --jq "
    [.[] | select(.draft | not) $stable_only
      | {tag: .tag_name, pre: .prerelease, asset: ([.assets[] | select(.name | test(env.PATTERN))] | first)}
      | select(.asset)]
    | first // empty
    | [.tag, .asset.browser_download_url, .pre] | @tsv")

  if [ -z "$release" ]; then
    echo "skip $name: no $channel release of $repo has an asset matching $pattern" >&2
    continue
  fi
  IFS=$'\t' read -r tag url prerelease <<< "$release"

  hmod=$WORK/$name.hmod
  if ! curl -fsSL -o "$hmod" "$url"; then
    echo "skip $name: download failed ($url)" >&2
    continue
  fi

  dir=$REPO_DIR/$name.hmod
  mkdir -p "$dir"
  echo "$url" > "$dir/link"
  md5sum "$hmod" | cut -d' ' -f1 > "$dir/md5"
  sha1sum "$hmod" | cut -d' ' -f1 > "$dir/sha1"

  readme=$(tar -tf "$hmod" | grep -m1 -iE '^(\./)?readme(\.md|\.txt)?$' || true)
  readme_out=$dir/readme.md
  if [ -n "$readme" ]; then
    readme_out=$dir/$(basename "$readme" | tr '[:upper:]' '[:lower:]')
    tar -xOf "$hmod" "$readme" > "$WORK/readme"
  else
    printf -- '---\nName: %s\nCreator: %s\nVersion: %s\n---\n' "$name" "${repo%%/*}" "${tag#v}" > "$WORK/readme"
  fi
  NAME="$name" CATEGORY="$category" awk '
    NR == 1 && !/^---/ { print "---"; print "Name: " ENVIRON["NAME"]; print "Category: " ENVIRON["CATEGORY"]; print "---" }
    NR == 1 && /^---/ { print; head = 1; next }
    head && /^Category:/ { if (!c) print "Category: " ENVIRON["CATEGORY"]; c = 1; next }
    head && /^---/ { if (!c) print "Category: " ENVIRON["CATEGORY"]; head = 0 }
    { print }
  ' "$WORK/readme" > "$readme_out"

  title=$(sed -n '1{/^---/!q}; 2,/^---/{s/^Name:[[:space:]]*//p}' "$readme_out" | head -1)
  title=${title:-$name}
  release_label=$tag
  [ "$prerelease" = true ] && release_label="$tag (pre-release)"

  [ -n "${cat_md[$category]+x}" ] || categories+=("$category")
  cat_md[$category]+="- **$title** - $release_label${description:+ - $description} ([source](https://github.com/$repo))"$'\n'
  cat_rows[$category]+="<tr><td>$(printf '%s' "$title" | html_escape)${description:+<br><small>$(printf '%s' "$description" | html_escape)</small>}</td><td>$(printf '%s' "$release_label" | html_escape)</td><td><a href=\"$url\">$name.hmod</a></td><td><a href=\"https://github.com/$repo\">$repo</a></td></tr>
"

  echo "$name.hmod" >> "$REPO_DIR/list"
  echo "$name: $tag ($category)"
done < sources.txt

mods_md=""
sections=""
for category in "${categories[@]}"; do
  mods_md+="### $category"$'\n\n'"${cat_md[$category]}"$'\n'
  sections+="<h2>$(printf '%s' "$category" | html_escape)</h2>
<div class=\"scroll\">
<table>
<thead><tr><th>Mod</th><th>Release</th><th>Download</th><th>Source</th></tr></thead>
<tbody>
${cat_rows[$category]}</tbody>
</table>
</div>
"
done

MODS="$mods_md" UPDATED="$(date -u +%Y-%m-%d)" awk '
  /^\{\{MODS\}\}$/ { printf "%s", ENVIRON["MODS"]; next }
  { gsub(/\{\{UPDATED\}\}/, ENVIRON["UPDATED"]); print }
' readme.md > "$REPO_DIR/readme.md"

(cd "$REPO_DIR" && tar -czf pack.tgz list readme.md ./*.hmod)

cat > "$OUT/index.html" << HTML
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>DefKorns' Mods</title>
<style>
  :root { color-scheme: light dark; --fg: #1d1d1f; --bg: #fff; --muted: #6e6e73; --line: #d2d2d7; --code: #f2f2f5; }
  @media (prefers-color-scheme: dark) { :root { --fg: #f5f5f7; --bg: #1c1c1e; --muted: #a1a1a6; --line: #3a3a3c; --code: #2c2c2e; } }
  body { margin: 0 auto; max-width: 860px; padding: 32px 16px; font: 16px/1.5 system-ui, sans-serif; color: var(--fg); background: var(--bg); }
  p { color: var(--muted); }
  code { background: var(--code); padding: 2px 6px; border-radius: 4px; word-break: break-all; }
  .scroll { overflow-x: auto; }
  table { width: 100%; border-collapse: collapse; margin-top: 16px; }
  th, td { text-align: left; padding: 8px; border-bottom: 1px solid var(--line); }
  a { color: inherit; }
  h2 { margin-top: 32px; }
  small { color: var(--muted); }
</style>
</head>
<body>
<h1>DefKorns' Mods</h1>
<p>hakchi2-CE mod repository. In hakchi, open <strong>Manage repositories</strong> and add:</p>
<p><code>$SITE_URL</code></p>
$sections</body>
</html>
HTML
