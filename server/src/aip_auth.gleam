/// AIP (ATProto Identity Provider) authentication module
///
/// Validates tokens by calling AIP's /api/atprotocol/session endpoint.
/// AIP handles token refresh internally — Quickslice doesn't need to.
import auth_types.{
  type AtprotoSession, type AuthError, type UserInfo, AipSigning, AtprotoSession,
  NetworkError, ParseError, SessionNotFound, UnauthorizedToken, UserInfo,
}
import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

import lib/http_client

/// Resolve both user info and ATP session via AIP in a single call
pub fn resolve(
  aip_base_url: String,
  token: String,
  delegate_for: Option(String),
) -> Result(#(UserInfo, AtprotoSession), AuthError) {
  // Build the AIP session URL
  let base_path =
    aip_base_url <> "/api/atprotocol/session?access_token_type=best"
  let url = case delegate_for {
    Some(did) -> base_path <> "&delegate_for=" <> did
    None -> base_path
  }

  // Build the request
  let req_result =
    request.to(url)
    |> result.map(fn(req) {
      req
      |> request.set_header("authorization", "Bearer " <> token)
    })

  use req <- result.try(
    req_result
    |> result.map_error(fn(_) { NetworkError }),
  )

  // Send the request
  use resp <- result.try(
    http_client.send(req)
    |> result.map_error(fn(_) { NetworkError }),
  )

  // Check status code
  case resp.status {
    200 -> {
      use #(user_info, session) <- result.try(parse_aip_session_response(
        resp.body,
      ))
      // For delegate flows, populate AipSigning so Quickslice can call
      // AIP's /api/atprotocol/dpop-proof endpoint for per-request signing
      // instead of signing locally with a private key
      let session = case delegate_for {
        Some(_) ->
          AtprotoSession(
            ..session,
            dpop_jwk: "",
            aip_signing: Some(AipSigning(
              base_url: aip_base_url,
              auth_token: token,
              delegate_for: delegate_for,
            )),
          )
        None -> AtprotoSession(..session, aip_signing: None)
      }
      Ok(#(user_info, session))
    }
    401 -> Error(UnauthorizedToken)
    403 -> Error(UnauthorizedToken)
    404 -> Error(SessionNotFound)
    _ -> Error(NetworkError)
  }
}

/// Parse AIP's /api/atprotocol/session response into UserInfo + AtprotoSession
fn parse_aip_session_response(
  body: String,
) -> Result(#(UserInfo, AtprotoSession), AuthError) {
  let decoder = {
    use did <- decode.field("did", decode.string)
    use pds_endpoint <- decode.field("pds_endpoint", decode.string)
    use access_token <- decode.field("access_token", decode.string)
    use dpop_key <- decode.optional_field(
      "dpop_key",
      None,
      decode.optional(decode.string),
    )
    decode.success(#(did, pds_endpoint, access_token, dpop_key))
  }

  case json.parse(body, decoder) {
    Ok(#(did, pds_endpoint, access_token, dpop_key)) -> {
      let dpop_jwk = case dpop_key {
        Some(key) -> key
        None -> ""
      }
      Ok(#(
        UserInfo(sub: did, did: did),
        AtprotoSession(
          pds_endpoint: pds_endpoint,
          access_token: access_token,
          dpop_jwk: dpop_jwk,
          aip_signing: None,
        ),
      ))
    }
    Error(_) -> Error(ParseError)
  }
}

/// Request a DPoP proof from AIP's signing endpoint
///
/// Returns #(dpop_proof, access_token) on success.
/// The proof is single-use and AIP re-checks delegation on every call.
pub fn request_dpop_proof(
  aip_base_url: String,
  auth_token: String,
  method: String,
  url: String,
  delegate_for: Option(String),
  nonce: Option(String),
) -> Result(#(String, String), AuthError) {
  let request_body =
    json.to_string(json.object(
      [
        #("method", json.string(method)),
        #("url", json.string(url)),
      ]
      |> append_optional("delegate_for", delegate_for)
      |> append_optional("nonce", nonce),
    ))

  let endpoint = aip_base_url <> "/api/atprotocol/dpop-proof"

  let req_result =
    request.to(endpoint)
    |> result.map(fn(req) {
      req
      |> request.set_method(http.Post)
      |> request.set_header("authorization", "Bearer " <> auth_token)
      |> request.set_header("content-type", "application/json")
      |> request.set_body(request_body)
    })

  use req <- result.try(
    req_result
    |> result.map_error(fn(_) { NetworkError }),
  )

  use resp <- result.try(
    http_client.send(req)
    |> result.map_error(fn(_) { NetworkError }),
  )

  case resp.status {
    200 -> parse_dpop_proof_response(resp.body)
    401 -> Error(UnauthorizedToken)
    403 -> Error(UnauthorizedToken)
    404 -> Error(SessionNotFound)
    _ -> Error(NetworkError)
  }
}

/// Parse AIP's /api/atprotocol/dpop-proof response
fn parse_dpop_proof_response(
  body: String,
) -> Result(#(String, String), AuthError) {
  let decoder = {
    use dpop_proof <- decode.field("dpop_proof", decode.string)
    use access_token <- decode.field("access_token", decode.string)
    decode.success(#(dpop_proof, access_token))
  }

  case json.parse(body, decoder) {
    Ok(result) -> Ok(result)
    Error(_) -> Error(ParseError)
  }
}

/// Helper to append an optional JSON field to a list of key-value pairs
fn append_optional(
  fields: List(#(String, json.Json)),
  key: String,
  value: Option(String),
) -> List(#(String, json.Json)) {
  case value {
    Some(v) -> list.append(fields, [#(key, json.string(v))])
    None -> fields
  }
}
