#!/usr/bin/env bash
# Builds the hakchi2-CE repository into site/ from the latest GitHub release
# of every entry in sources.txt. Needs gh (authenticated), curl and tar.
set -euo pipefail

cd "$(dirname "$0")"
OUT=site
REPO_DIR=$OUT/.repo
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

rm -rf "$OUT"
mkdir -p "$REPO_DIR"
touch "$OUT/.nojekyll"
cp readme.md "$REPO_DIR/readme.md"
: > "$REPO_DIR/list"

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

  echo "$name.hmod" >> "$REPO_DIR/list"
  echo "$name: $tag"
done < sources.txt

(cd "$REPO_DIR" && tar -czf pack.tgz list readme.md ./*.hmod)
