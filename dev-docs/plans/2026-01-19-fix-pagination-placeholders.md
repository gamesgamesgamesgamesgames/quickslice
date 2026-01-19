# Fix Pagination Cursor Placeholder Bug

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix cursor-based pagination (`after`/`before`) which returns 0 results on PostgreSQL due to incorrect SQL placeholders.

**Architecture:** The `build_cursor_where_clause` function in `pagination.gleam` uses literal `?` placeholders, but PostgreSQL requires numbered placeholders (`$1`, `$2`, etc.). We need to pass the executor and a starting index so proper placeholders can be generated.

**Tech Stack:** Gleam, PostgreSQL, SQLite

---

## Root Cause

In `server/src/database/queries/pagination.gleam`, the `build_cursor_where_clause` and `build_progressive_clauses` functions build SQL with literal `?`:

```gleam
let new_part = field_ref <> " = ?"  // Line 261
let comparison_part = field_ref <> " " <> comparison_op <> " ?"  // Line 273
```

But PostgreSQL needs `$1, $2, $3`. The executor has a `placeholder(index)` function that returns the correct format for each dialect, but it's not being used.

---

### Task 1: Update `build_cursor_where_clause` Signature

**Files:**
- Modify: `server/src/database/queries/pagination.gleam:210-237`

**Step 1: Update function signature to accept start_index**

Change the function signature from:

```gleam
pub fn build_cursor_where_clause(
  exec: Executor,
  decoded_cursor: DecodedCursor,
  sort_by: Option(List(#(String, String))),
  is_before: Bool,
) -> #(String, List(String)) {
```

To:

```gleam
pub fn build_cursor_where_clause(
  exec: Executor,
  decoded_cursor: DecodedCursor,
  sort_by: Option(List(#(String, String))),
  is_before: Bool,
  start_index: Int,
) -> #(String, List(String)) {
```

**Step 2: Update the call to build_progressive_clauses**

Change line 225-231 from:

```gleam
      let clauses =
        build_progressive_clauses(
          exec,
          sort_fields,
          decoded_cursor.field_values,
          decoded_cursor.cid,
          is_before,
        )
```

To:

```gleam
      let clauses =
        build_progressive_clauses(
          exec,
          sort_fields,
          decoded_cursor.field_values,
          decoded_cursor.cid,
          is_before,
          start_index,
        )
```

**Step 3: Run build to check for compilation errors**

Run: `cd ~/code/quickslice/server && gleam build`
Expected: Compilation errors about missing argument (we'll fix callers in Task 3)

---

### Task 2: Update `build_progressive_clauses` to Use Numbered Placeholders

**Files:**
- Modify: `server/src/database/queries/pagination.gleam:239-307`

**Step 1: Update function signature**

Change line 240-246 from:

```gleam
fn build_progressive_clauses(
  exec: Executor,
  sort_fields: List(#(String, String)),
  field_values: List(String),
  cid: String,
  is_before: Bool,
) -> #(List(String), List(String)) {
```

To:

```gleam
fn build_progressive_clauses(
  exec: Executor,
  sort_fields: List(#(String, String)),
  field_values: List(String),
  cid: String,
  is_before: Bool,
  start_index: Int,
) -> #(List(String), List(String)) {
```

**Step 2: Rewrite the function body to track placeholder indices**

Replace the entire function body (lines 247-307) with:

```gleam
fn build_progressive_clauses(
  exec: Executor,
  sort_fields: List(#(String, String)),
  field_values: List(String),
  cid: String,
  is_before: Bool,
  start_index: Int,
) -> #(List(String), List(String)) {
  // Build clauses with tracked parameter index
  let #(clauses, params, next_index) =
    list.index_fold(sort_fields, #([], [], start_index), fn(acc, field, i) {
      let #(acc_clauses, acc_params, param_index) = acc

      // Build equality parts for prior fields
      let #(equality_parts, equality_params, idx_after_eq) = case i {
        0 -> #([], [], param_index)
        _ -> {
          list.index_fold(
            list.take(sort_fields, i),
            #([], [], param_index),
            fn(eq_acc, prior_field, j) {
              let #(eq_parts, eq_params, eq_idx) = eq_acc
              let value = list_at(field_values, j) |> result.unwrap("")
              let field_ref = build_cursor_field_reference(exec, prior_field.0)
              let placeholder = executor.placeholder(exec, eq_idx)
              let new_part = field_ref <> " = " <> placeholder
              #(
                list.append(eq_parts, [new_part]),
                list.append(eq_params, [value]),
                eq_idx + 1,
              )
            },
          )
        }
      }

      let value = list_at(field_values, i) |> result.unwrap("")
      let comparison_op = get_comparison_operator(field.1, is_before)
      let field_ref = build_cursor_field_reference(exec, field.0)
      let placeholder = executor.placeholder(exec, idx_after_eq)

      let comparison_part = field_ref <> " " <> comparison_op <> " " <> placeholder
      let all_parts = list.append(equality_parts, [comparison_part])
      let all_params = list.append(equality_params, [value])

      let clause = "(" <> string.join(all_parts, " AND ") <> ")"

      #(
        list.append(acc_clauses, [clause]),
        list.append(acc_params, all_params),
        idx_after_eq + 1,
      )
    })

  // Build final clause with all fields equal and CID comparison
  let #(final_equality_parts, final_equality_params, idx_after_final_eq) =
    list.index_fold(sort_fields, #([], [], next_index), fn(acc, field, j) {
      let #(parts, params, idx) = acc
      let value = list_at(field_values, j) |> result.unwrap("")
      let field_ref = build_cursor_field_reference(exec, field.0)
      let placeholder = executor.placeholder(exec, idx)
      #(
        list.append(parts, [field_ref <> " = " <> placeholder]),
        list.append(params, [value]),
        idx + 1,
      )
    })

  let last_field = list.last(sort_fields) |> result.unwrap(#("", "desc"))
  let cid_comparison_op = get_comparison_operator(last_field.1, is_before)
  let cid_placeholder = executor.placeholder(exec, idx_after_final_eq)

  let final_parts =
    list.append(final_equality_parts, ["cid " <> cid_comparison_op <> " " <> cid_placeholder])
  let final_params = list.append(final_equality_params, [cid])

  let final_clause = "(" <> string.join(final_parts, " AND ") <> ")"
  let all_clauses = list.append(clauses, [final_clause])
  let all_params = list.append(params, final_params)

  #(all_clauses, all_params)
}
```

**Step 3: Run build to verify syntax**

Run: `cd ~/code/quickslice/server && gleam build`
Expected: Compilation errors about callers (we'll fix in Task 3)

---

### Task 3: Update All Callers in records.gleam

**Files:**
- Modify: `server/src/database/repositories/records.gleam`

There are 5 places that call `build_cursor_where_clause`. Each needs to pass the current parameter count + 1 as the start_index.

**Step 1: Update get_by_collection_paginated (line ~548)**

Find lines 548-555 and change from:

```gleam
          let #(cursor_where, cursor_params) =
            pagination.build_cursor_where_clause(
              exec,
              decoded_cursor,
              sort_by,
              !is_forward,
            )
```

To:

```gleam
          let #(cursor_where, cursor_params) =
            pagination.build_cursor_where_clause(
              exec,
              decoded_cursor,
              sort_by,
              !is_forward,
              list.length(bind_values) + 1,
            )
```

**Step 2: Update get_by_collection_paginated_with_where (line ~701)**

Find lines 701-708 and change from:

```gleam
          let #(cursor_where, cursor_params) =
            pagination.build_cursor_where_clause(
              exec,
              decoded_cursor,
              sort_by,
              !is_forward,
            )
```

To:

```gleam
          let #(cursor_where, cursor_params) =
            pagination.build_cursor_where_clause(
              exec,
              decoded_cursor,
              sort_by,
              !is_forward,
              list.length(bind_values) + 1,
            )
```

**Step 3: Update get_by_reference_field_paginated (line ~941)**

Find lines 941-948 and change from:

```gleam
          let #(cursor_where, cursor_params) =
            pagination.build_cursor_where_clause(
              exec,
              decoded_cursor,
              sort_by,
              !is_forward,
            )
```

To:

```gleam
          let #(cursor_where, cursor_params) =
            pagination.build_cursor_where_clause(
              exec,
              decoded_cursor,
              sort_by,
              !is_forward,
              list.length(with_where_values) + 1,
            )
```

**Step 4: Update get_by_dids_and_collection_paginated (line ~1297)**

Find lines 1297-1304 and change from:

```gleam
          let #(cursor_where, cursor_params) =
            pagination.build_cursor_where_clause(
              exec,
              decoded_cursor,
              sort_by,
              !is_forward,
            )
```

To:

```gleam
          let #(cursor_where, cursor_params) =
            pagination.build_cursor_where_clause(
              exec,
              decoded_cursor,
              sort_by,
              !is_forward,
              list.length(with_where_values) + 1,
            )
```

**Step 5: Build to verify all callers are updated**

Run: `cd ~/code/quickslice/server && gleam build`
Expected: BUILD SUCCESS

**Step 6: Commit the fix**

```bash
cd ~/code/quickslice/server
git add src/database/queries/pagination.gleam src/database/repositories/records.gleam
git commit -m "fix: use numbered placeholders in cursor WHERE clause for PostgreSQL

The build_cursor_where_clause function was using literal '?' placeholders,
which works for SQLite but fails on PostgreSQL (which needs \$1, \$2, etc.).

Now accepts a start_index parameter and uses executor.placeholder() to
generate the correct format for each database dialect.

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

---

### Task 4: Update Unit Tests

**Files:**
- Modify: `server/test/pagination_test.gleam`

The existing tests check for `?` placeholders. They pass because tests use SQLite. We need to update tests to pass the new start_index parameter.

**Step 1: Update build_where_single_field_desc_test**

Find the test around line 272 and change:

```gleam
  let #(sql, params) =
    pagination.build_cursor_where_clause(exec, decoded, sort_by, False)
```

To:

```gleam
  let #(sql, params) =
    pagination.build_cursor_where_clause(exec, decoded, sort_by, False, 1)
```

**Step 2: Update build_where_single_field_asc_test**

Find the test around line 298 and change:

```gleam
  let #(sql, params) =
    pagination.build_cursor_where_clause(exec, decoded, sort_by, False)
```

To:

```gleam
  let #(sql, params) =
    pagination.build_cursor_where_clause(exec, decoded, sort_by, False, 1)
```

**Step 3: Update build_where_json_field_test**

Find the test around line 324 and change:

```gleam
  let #(sql, params) =
    pagination.build_cursor_where_clause(exec, decoded, sort_by, False)
```

To:

```gleam
  let #(sql, params) =
    pagination.build_cursor_where_clause(exec, decoded, sort_by, False, 1)
```

**Step 4: Update build_where_nested_json_field_test**

Find the test around line 345 and change:

```gleam
  let #(sql, params) =
    pagination.build_cursor_where_clause(exec, decoded, sort_by, False)
```

To:

```gleam
  let #(sql, params) =
    pagination.build_cursor_where_clause(exec, decoded, sort_by, False, 1)
```

**Step 5: Update build_where_multi_field_test**

Find the test around line 366 and change:

```gleam
  let #(sql, params) =
    pagination.build_cursor_where_clause(exec, decoded, sort_by, False)
```

To:

```gleam
  let #(sql, params) =
    pagination.build_cursor_where_clause(exec, decoded, sort_by, False, 1)
```

**Step 6: Update build_where_backward_test**

Find the test around line 398 and change:

```gleam
  let #(sql, params) =
    pagination.build_cursor_where_clause(exec, decoded, sort_by, True)
```

To:

```gleam
  let #(sql, params) =
    pagination.build_cursor_where_clause(exec, decoded, sort_by, True, 1)
```

**Step 7: Run tests**

Run: `cd ~/code/quickslice/server && gleam test`
Expected: All tests pass (SQLite uses `?` regardless of index, so assertions still work)

**Step 8: Commit test updates**

```bash
cd ~/code/quickslice/server
git add test/pagination_test.gleam
git commit -m "test: update pagination tests with start_index parameter

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

---

### Task 5: Manual Verification with MCP

**Step 1: Test pagination via quickslice MCP**

Run this GraphQL query:

```graphql
query {
  gamesGamesgamesgamesgamesGame(first: 2) {
    pageInfo {
      hasNextPage
      endCursor
    }
    edges {
      node { name }
    }
  }
}
```

**Step 2: Test pagination with cursor**

Use the `endCursor` from step 1:

```graphql
query {
  gamesGamesgamesgamesgamesGame(first: 2, after: "<endCursor>") {
    pageInfo {
      hasNextPage
      endCursor
    }
    edges {
      node { name }
    }
  }
}
```

Expected: Returns the NEXT 2 records (not empty, not the same as page 1)

**Step 3: Commit verification note (optional)**

If all works, the fix is complete.
