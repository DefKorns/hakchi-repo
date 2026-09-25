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
rows=""
mods_md=""

html_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

while IFS= read -r line; do
  line=${line%$'\r'}
  read -r repo name pattern channel <<< "$line" || true
  case "$repo" in '' | \#*) continue ;; esac

  stable_only='| select(.prerelease | not)'
  [ "${channel:-stable}" = pre ] && stable_only=''

  release=$(PATTERN="$pattern" gh api "repos/$repo/releases?per_page=30" --jq "
    [.[] | select(.draft | not) $stable_only
      | {tag: .tag_name, asset: ([.assets[] | select(.name | test(env.PATTERN))] | first)}
      | select(.asset)]
    | first // empty
    | [.tag, .asset.browser_download_url] | @tsv")

  if [ -z "$release" ]; then
    echo "skip $name: no $channel release of $repo has an asset matching $pattern" >&2
    continue
  fi
  IFS=$'\t' read -r tag url <<< "$release"

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
  if [ -n "$readme" ]; then
    tar -xOf "$hmod" "$readme" > "$dir/$(basename "$readme" | tr '[:upper:]' '[:lower:]')"
  else
    printf -- '---\nName: %s\nCreator: %s\nVersion: %s\n---\n' "$name" "${repo%%/*}" "${tag#v}" > "$dir/readme.md"
  fi

  title=$(sed -n '1{/^---/!q}; 2,/^---/{s/^Name:[[:space:]]*//p}' "$dir"/readme* | head -1)
  title=${title:-$name}
  mods_md+="- **$title** - $tag ([source](https://github.com/$repo))"$'\n'
  title=$(printf '%s' "$title" | html_escape)
  rows+="<tr><td>$title</td><td>$(printf '%s' "$tag" | html_escape)</td><td><a href=\"$url\">$name.hmod</a></td><td><a href=\"https://github.com/$repo\">$repo</a></td></tr>
"

  echo "$name.hmod" >> "$REPO_DIR/list"
  echo "$name: $tag"
done < sources.txt

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
</style>
</head>
<body>
<h1>DefKorns' Mods</h1>
<p>hakchi2-CE mod repository. In hakchi, open <strong>Manage repositories</strong> and add:</p>
<p><code>$SITE_URL</code></p>
<div class="scroll">
<table>
<thead><tr><th>Mod</th><th>Release</th><th>Download</th><th>Source</th></tr></thead>
<tbody>
$rows</tbody>
</table>
</div>
</body>
</html>
HTML
