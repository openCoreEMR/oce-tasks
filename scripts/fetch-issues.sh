#!/usr/bin/env bash
set -euo pipefail

# Fetch all open issues from a GitHub repo using GraphQL (includes issueType).
# Usage: fetch-issues.sh <owner/repo> <output-file> [since-timestamp]
#
# The optional since-timestamp filters to issues updated after that time.

readonly repo="${1:?Usage: fetch-issues.sh <owner/repo> <output-file> [since-timestamp]}"
readonly output="${2:?Usage: fetch-issues.sh <owner/repo> <output-file> [since-timestamp]}"
readonly since="${3:-}"

readonly owner="${repo%/*}"
readonly name="${repo#*/}"

# Build the filterBy clause
filter='states: OPEN'
if [[ -n "$since" ]]; then
    filter="$filter, filterBy: {since: \"$since\"}"
fi

# GraphQL query with pagination
read -r -d '' query <<'GRAPHQL' || true
query($owner: String!, $name: String!, $cursor: String) {
  repository(owner: $owner, name: $name) {
    issues(first: 100, after: $cursor, %FILTER%, orderBy: {field: UPDATED_AT, direction: DESC}) {
      nodes {
        number
        title
        state
        author { login }
        createdAt
        updatedAt
        labels(first: 20) { nodes { name } }
        body
        comments(first: 100) {
          nodes {
            createdAt
            author { login }
          }
        }
        reactionGroups {
          content
          reactors { totalCount }
        }
        closedByPullRequestsReferences(first: 10) {
          nodes { number }
        }
        issueType { name }
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
  }
}
GRAPHQL

# Substitute the filter into the query
query="${query//%FILTER%/$filter}"

# Fetch all pages
all_issues='[]'
cursor='null'
page=1

while true; do
    if [[ "$cursor" == 'null' ]]; then
        result=$(gh api graphql -f query="$query" -f owner="$owner" -f name="$name")
    else
        result=$(gh api graphql -f query="$query" -f owner="$owner" -f name="$name" -f cursor="$cursor")
    fi

    # Extract issues from this page
    issues=$(echo "$result" | jq '.data.repository.issues.nodes')
    count=$(echo "$issues" | jq 'length')

    # Append to all_issues
    all_issues=$(echo "$all_issues" "$issues" | jq -s '.[0] + .[1]')

    echo "Fetched page $page ($count issues)" >&2

    # Check for more pages
    has_next=$(echo "$result" | jq -r '.data.repository.issues.pageInfo.hasNextPage')
    if [[ "$has_next" != 'true' ]]; then
        break
    fi

    cursor=$(echo "$result" | jq -r '.data.repository.issues.pageInfo.endCursor')
    ((page++))
done

# Transform to match the format expected by sync-triage
# (flatten author, labels, etc. to match gh issue list output)
echo "$all_issues" | jq '
  [.[] | {
    number,
    title,
    state: (.state | ascii_downcase),
    author: .author,
    createdAt,
    updatedAt,
    labels: [.labels.nodes[].name],
    body,
    comments: [.comments.nodes[] | {createdAt, author}],
    reactionGroups: [.reactionGroups[] | {content, reactors: .reactors}],
    closedByPullRequestsReferences: [.closedByPullRequestsReferences.nodes[] | {number}],
    issueType: .issueType
  }]
' > "$output"

total=$(jq length "$output")
echo "Wrote $total issues to $output"
