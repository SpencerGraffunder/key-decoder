#!/usr/bin/env bash
# Wait for the GH Actions run of CURRENT HEAD and print a compact digest.
cd "$(dirname "$0")/.." || exit 1
SHA=$(git rev-parse HEAD)
echo "HEAD=$(git rev-parse --short HEAD)"
RUN=""
for _ in $(seq 1 60); do
  RUN=$(gh run list --limit 10 --json databaseId,headSha --jq ".[] | select(.headSha==\"$SHA\") | .databaseId" 2>/dev/null | head -1)
  [ -n "$RUN" ] && break
  sleep 10
done
[ -z "$RUN" ] && { echo "NO_RUN_FOUND_FOR_HEAD"; exit 2; }
echo "RUN=$RUN"
STATUS=$(gh run view "$RUN" --json status --jq '.status' 2>/dev/null || echo queued)
while [ "$STATUS" != "completed" ]; do sleep 20; STATUS=$(gh run view "$RUN" --json status --jq '.status' 2>/dev/null || echo queued); done
CONCLUSION=$(gh run view "$RUN" --json conclusion --jq '.conclusion')
echo "CONCLUSION=$CONCLUSION"
if [ "$CONCLUSION" != "success" ]; then
  gh run view "$RUN" --log-failed 2>&1 | grep -E "error:|error generated|Testing failed|FATAL|xcodebuild: error|The following build commands failed" | grep -vE "warnings-as-errors' flag|\bCompiling\b" | sed -E 's/^[^\t]*\t[^\t]*\t[0-9TZ:.-]+Z? //' | sort -u | head -40
  echo "--- failing test cases ---"
  gh run view "$RUN" --log-failed 2>&1 | grep -E "Test Case '.*' failed|XCTAssert.*failed" | sed -E 's/^[^\t]*\t[^\t]*\t[0-9TZ:.-]+Z? //' | sort -u | head -60
fi
