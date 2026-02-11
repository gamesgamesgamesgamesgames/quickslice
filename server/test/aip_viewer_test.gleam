/// Integration test: viewer query with AIP auth provider
///
/// Verifies that the viewer root query works correctly when AUTH_PROVIDER=aip.
/// The fix ensures token verification uses the local DB (verify_token) instead
/// of calling AIP's session endpoint (which would fail for Quickslice tokens).
///
/// Key test strategy: We use auth_types.Aip("http://localhost:9999") — a URL
/// that nothing is listening on. If the code incorrectly tries to contact AIP
/// for token verification, the test will fail. The test passing proves the fix
/// correctly avoids calling AIP.
import auth_types
import database/repositories/actors
import database/repositories/lexicons
import gleam/http
import gleam/json
import gleam/option.{None}
import gleam/string
import gleeunit/should
import handlers/graphql as graphql_handler
import lib/oauth/did_cache
import test_helpers
import wisp
import wisp/simulate

// Minimal lexicon needed to build a schema
fn create_minimal_lexicon() -> String {
  json.object([
    #("lexicon", json.int(1)),
    #("id", json.string("test.aip.item")),
    #(
      "defs",
      json.object([
        #(
          "main",
          json.object([
            #("type", json.string("record")),
            #("key", json.string("tid")),
            #(
              "record",
              json.object([
                #("type", json.string("object")),
                #(
                  "required",
                  json.array([json.string("name")], of: fn(x) { x }),
                ),
                #(
                  "properties",
                  json.object([
                    #("name", json.object([#("type", json.string("string"))])),
                  ]),
                ),
              ]),
            ),
          ]),
        ),
      ]),
    ),
  ])
  |> json.to_string
}

/// Test: viewer query returns DID and handle with AIP auth provider
///
/// This is the critical test — it uses auth_types.Aip with an unreachable URL.
/// Before the fix, execute_query_with_db would try to call AIP's session
/// endpoint to verify the token, which would fail because:
/// 1. The URL is unreachable
/// 2. Even in production, AIP doesn't recognize Quickslice OAuth tokens
///
/// After the fix, the code always uses verify_token (local DB lookup),
/// so the AIP URL is never contacted and the viewer resolves correctly.
pub fn viewer_query_returns_did_and_handle_with_aip_auth_test() {
  // Setup database
  let assert Ok(exec) = test_helpers.create_test_db()
  let assert Ok(_) = test_helpers.create_lexicon_table(exec)
  let assert Ok(_) = test_helpers.create_record_table(exec)
  let assert Ok(_) = test_helpers.create_config_table(exec)
  let assert Ok(_) = test_helpers.create_actor_table(exec)
  let assert Ok(_) = test_helpers.create_oauth_tables(exec)

  // Insert test token and actor
  let assert Ok(_) =
    test_helpers.insert_test_token(exec, "aip-test-token", "did:plc:aipuser")
  let assert Ok(_) = actors.upsert(exec, "did:plc:aipuser", "aipuser.test")

  // Insert a lexicon so the schema can be built
  let assert Ok(_) =
    lexicons.insert(exec, "test.aip.item", create_minimal_lexicon())

  // Query the viewer field
  let query =
    json.object([
      #("query", json.string("{ viewer { did handle } }")),
    ])
    |> json.to_string

  let request =
    simulate.request(http.Post, "/graphql")
    |> simulate.string_body(query)
    |> simulate.header("content-type", "application/json")
    |> simulate.header("authorization", "Bearer aip-test-token")

  let assert Ok(cache) = did_cache.start()

  // Use AIP auth provider with UNREACHABLE URL
  // If the code contacts this URL, the test will fail
  let response =
    graphql_handler.handle_graphql_request(
      request,
      exec,
      cache,
      None,
      "",
      "",
      auth_types.Aip("http://localhost:9999"),
    )

  let assert wisp.Text(body) = response.body

  // Should succeed
  response.status |> should.equal(200)

  // Viewer should contain the DID
  string.contains(body, "did:plc:aipuser") |> should.be_true

  // Viewer should contain the handle
  string.contains(body, "aipuser.test") |> should.be_true
}

/// Test: viewer query returns null when unauthenticated with AIP auth provider
pub fn viewer_query_returns_null_when_unauthenticated_with_aip_auth_test() {
  // Setup database
  let assert Ok(exec) = test_helpers.create_test_db()
  let assert Ok(_) = test_helpers.create_lexicon_table(exec)
  let assert Ok(_) = test_helpers.create_record_table(exec)
  let assert Ok(_) = test_helpers.create_config_table(exec)
  let assert Ok(_) = test_helpers.create_actor_table(exec)
  let assert Ok(_) = test_helpers.create_oauth_tables(exec)

  // Insert a lexicon so the schema can be built
  let assert Ok(_) =
    lexicons.insert(exec, "test.aip.item", create_minimal_lexicon())

  // Query viewer WITHOUT auth token
  let query =
    json.object([
      #("query", json.string("{ viewer { did handle } }")),
    ])
    |> json.to_string

  let request =
    simulate.request(http.Post, "/graphql")
    |> simulate.string_body(query)
    |> simulate.header("content-type", "application/json")

  let assert Ok(cache) = did_cache.start()

  let response =
    graphql_handler.handle_graphql_request(
      request,
      exec,
      cache,
      None,
      "",
      "",
      auth_types.Aip("http://localhost:9999"),
    )

  let assert wisp.Text(body) = response.body

  // Should succeed
  response.status |> should.equal(200)

  // Viewer should be null
  string.contains(body, "\"viewer\": null") |> should.be_true
}

/// Test: viewer query also works with Internal auth (regression test)
pub fn viewer_query_returns_did_and_handle_with_internal_auth_test() {
  // Setup database
  let assert Ok(exec) = test_helpers.create_test_db()
  let assert Ok(_) = test_helpers.create_lexicon_table(exec)
  let assert Ok(_) = test_helpers.create_record_table(exec)
  let assert Ok(_) = test_helpers.create_config_table(exec)
  let assert Ok(_) = test_helpers.create_actor_table(exec)
  let assert Ok(_) = test_helpers.create_oauth_tables(exec)

  // Insert test token and actor
  let assert Ok(_) =
    test_helpers.insert_test_token(
      exec,
      "internal-test-token",
      "did:plc:internaluser",
    )
  let assert Ok(_) =
    actors.upsert(exec, "did:plc:internaluser", "internaluser.test")

  // Insert a lexicon so the schema can be built
  let assert Ok(_) =
    lexicons.insert(exec, "test.aip.item", create_minimal_lexicon())

  // Query the viewer field
  let query =
    json.object([
      #("query", json.string("{ viewer { did handle } }")),
    ])
    |> json.to_string

  let request =
    simulate.request(http.Post, "/graphql")
    |> simulate.string_body(query)
    |> simulate.header("content-type", "application/json")
    |> simulate.header("authorization", "Bearer internal-test-token")

  let assert Ok(cache) = did_cache.start()

  let response =
    graphql_handler.handle_graphql_request(
      request,
      exec,
      cache,
      None,
      "",
      "",
      auth_types.Internal,
    )

  let assert wisp.Text(body) = response.body

  // Should succeed
  response.status |> should.equal(200)

  // Viewer should contain the DID
  string.contains(body, "did:plc:internaluser") |> should.be_true

  // Viewer should contain the handle
  string.contains(body, "internaluser.test") |> should.be_true
}
