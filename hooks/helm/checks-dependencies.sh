#!/bin/bash

set -e

CHART_ARG="$1"

if [ -z "$CHART_ARG" ]; then
  echo "🔍 Auto-detecting changed Helm charts from git..."
  CHART_ARG=$(git diff --cached --name-only | grep -E '(^|/)Chart\.yaml$' | xargs -n1 dirname | paste -sd, -)
  if [ -z "$CHART_ARG" ]; then
    echo "✅ No changed charts detected, skipping"
    exit 0
  fi
  echo "📦 Charts to update: $CHART_ARG"
fi

# Temporary files
TMP_GRAPH="/tmp/chart_graph.$$"
TMP_PATHMAP="/tmp/chart_pathmap.$$"
TMP_VISITED="/tmp/chart_visited.$$"
TMP_FILTERED="/tmp/chart_filtered.$$"
TMP_SORTED="/tmp/chart_sorted.$$"

echo "" > "$TMP_GRAPH"
echo "" > "$TMP_PATHMAP"
echo "" > "$TMP_VISITED"
echo "" > "$TMP_FILTERED"
echo "" > "$TMP_SORTED"

realpath_compat() {
    if command -v realpath >/dev/null 2>&1; then
        realpath "$1"
    else
        python -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$1"
    fi
}

# Chart discovery (root and tests/)
echo "🔎 Discovering all charts..."
# shellcheck disable=SC2044
for chart_file in $(find . -type f -name "Chart.yaml" -path "./*/Chart.yaml" -o -path "./tests/*/Chart.yaml"); do
    chart_dir=$(dirname "$chart_file")
    chart_abs=$(realpath_compat "$chart_dir")
    echo "$chart_abs:$chart_dir" >> "$TMP_PATHMAP"

    # Parse internal deps
    awk '
      /^dependencies:/ { in_deps = 1; next }
      in_deps && /^[[:space:]]*-/ { dep_block = 1; next }
      dep_block && /repository:[[:space:]]*file:\/\// {
        match($0, /file:\/\/[^[:space:]#\"]+/)
        if (RSTART > 0) {
          dep = substr($0, RSTART+7, RLENGTH-7)
          print dep
        }
      }
      in_deps && /^[^[:space:]]/ { in_deps = 0; dep_block = 0 }
    ' "$chart_file" | while read -r dep_rel; do
        dep_abs=$(realpath_compat "$chart_dir/$dep_rel")
        echo "$chart_abs $dep_abs" >> "$TMP_GRAPH"
    done
done

echo "📦 Charts discovered:"
cut -d':' -f2- "$TMP_PATHMAP"

# Graph traversal
visit_downward() {
    local node="$1"
    grep -q "^$node\$" "$TMP_VISITED" && return
    echo "$node" >> "$TMP_VISITED"
    grep "^$node " "$TMP_GRAPH" | cut -d' ' -f2 | while read -r child; do
        visit_downward "$child"
    done
}

if [ -z "$CHART_ARG" ]; then
    echo "🟡 No chart specified — processing all charts"
    # shellcheck disable=SC2013
    for chart_abs in $(cut -d':' -f1 "$TMP_PATHMAP"); do
        visit_downward "$chart_abs"
    done
else
    echo "🟢 Processing chart(s): $CHART_ARG"
    IFS=',' read -r -a TARGET_CHARTS <<< "$CHART_ARG"
    for chart_path in "${TARGET_CHARTS[@]}"; do
        if [ ! -d "$chart_path" ]; then
            echo "❌ Chart folder '$chart_path' not found."
            exit 1
        fi
        TARGET_PATH=$(realpath_compat "$chart_path")
        echo "🧪 Visiting chart: $TARGET_PATH"
        grep "^$TARGET_PATH " "$TMP_GRAPH" || echo "  ↪️  No dependencies"
        visit_downward "$TARGET_PATH"
    done
fi

echo "✅ Visited charts:"
cat "$TMP_VISITED"

# Filter graph
while read -r from to; do
    grep -q "^$from\$" "$TMP_VISITED" && grep -q "^$to\$" "$TMP_VISITED" && echo "$from $to" >> "$TMP_FILTERED"
done < "$TMP_GRAPH"

echo "📈 Filtered dependency edges:"
cat "$TMP_FILTERED"

# Topological sort
tsort "$TMP_FILTERED" > "$TMP_SORTED"

# Include any isolated charts not in sorted output
# shellcheck disable=SC2013
for node in $(cat "$TMP_VISITED"); do
    grep -q "^$node\$" "$TMP_SORTED" || echo "$node" >> "$TMP_SORTED"
done

echo "🔃 Topological update order (leaf → root):"
tac "$TMP_SORTED"

# Run helm updates
echo "🚀 Running helm dependency updates..."
while read -r abs_path; do
    rel_path=$(grep "^$abs_path:" "$TMP_PATHMAP" | cut -d':' -f2-)
    if [ -n "$rel_path" ]; then
        echo "🔄 helm dependency update $rel_path"
        helm dependency update "$rel_path" || echo "❌ Failed in $rel_path"
    fi
done < <(tac "$TMP_SORTED")

# Cleanup
rm -f "$TMP_GRAPH" "$TMP_PATHMAP" "$TMP_VISITED" "$TMP_FILTERED" "$TMP_SORTED"
