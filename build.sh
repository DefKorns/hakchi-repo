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
cp -r assets/. "$OUT/"
: > "$REPO_DIR/list"
categories=()
declare -A cat_md cat_rows

html_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }
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

  # the releases API now and then answers with an empty list
  release=""
  for attempt in 1 2 3 4 5; do
    release=$(PATTERN="$pattern" gh api "repos/$repo/releases?per_page=30" --jq "
      [.[] | select(.draft | not) $stable_only
        | {tag: .tag_name, pre: .prerelease, published: .published_at, asset: ([.assets[] | select(.name | test(env.PATTERN))] | first)}
        | select(.asset)]
      | sort_by(.published) | reverse
      | first // empty
      | [.tag, .asset.browser_download_url, .pre] | @tsv")
    [ -n "$release" ] && break
    [ "$attempt" -lt 5 ] && sleep 5
  done

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
  version_class="ver mono"
  version_title=
  if [ "$prerelease" = true ]; then
    version_class="ver mono pre"
    version_title=' title="pre-release"'
  fi
  search_text=$(printf '%s %s' "$title" "$description" | tr '[:upper:]' '[:lower:]' | html_escape)
  cat_rows[$category]+="      <li class=\"row\" data-text=\"$search_text\">
        <div><h3>$(printf '%s' "$title" | html_escape)</h3><p>$(printf '%s' "${description:-}" | html_escape)</p></div>
        <span class=\"$version_class\"$version_title>$tag</span>
        <div class=\"act\"><a class=\"dl\" href=\"$url\">Download</a><a class=\"src\" href=\"https://github.com/$repo\">Source</a></div>
      </li>
"

  echo "$name.hmod" >> "$REPO_DIR/list"
  echo "$name: $tag ($category)"
done < sources.txt

mods_md=""
sections=""
for category in "${categories[@]}"; do
  mods_md+="### $category"$'

'"${cat_md[$category]}"$'
'
  sections+="  <section class=\"group\">
    <h2>$(printf '%s' "$category" | html_escape)</h2>
    <ul class=\"rows\">
${cat_rows[$category]}    </ul>
  </section>
"
done

MODS="$mods_md" UPDATED="$(date -u +%Y-%m-%d)" awk '
  /^\{\{MODS\}\}$/ { printf "%s", ENVIRON["MODS"]; next }
  { gsub(/\{\{UPDATED\}\}/, ENVIRON["UPDATED"]); print }
' readme.md > "$REPO_DIR/readme.md"

(cd "$REPO_DIR" && tar -czf pack.tgz list readme.md ./*.hmod)

SECTIONS="$sections" SITE_URL="$SITE_URL" UPDATED="$(date -u +%Y-%m-%d)" awk '
  /^\{\{SECTIONS\}\}$/ { printf "%s", ENVIRON["SECTIONS"]; next }
  { gsub(/\{\{SITE_URL\}\}/, ENVIRON["SITE_URL"]); gsub(/\{\{UPDATED\}\}/, ENVIRON["UPDATED"]); print }
' template.html > "$OUT/index.html"
