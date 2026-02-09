import gleam/option.{type Option}

/// Shared authentication types used by atproto_auth and aip_auth
/// UserInfo response from OAuth provider
pub type UserInfo {
  UserInfo(sub: String, did: String)
}

/// Context for requesting DPoP proofs from AIP
pub type AipSigning {
  AipSigning(base_url: String, auth_token: String, delegate_for: Option(String))
}

/// ATProto session data
pub type AtprotoSession {
  AtprotoSession(
    pds_endpoint: String,
    access_token: String,
    dpop_jwk: String,
    aip_signing: Option(AipSigning),
  )
}

/// Error type for authentication operations
pub type AuthError {
  MissingAuthHeader
  InvalidAuthHeader
  UnauthorizedToken
  TokenExpired
  SessionNotFound
  SessionNotReady
  RefreshFailed(String)
  DIDResolutionFailed(String)
  NetworkError
  ParseError
}

/// Auth provider configuration
pub type AuthProvider {
  /// Use Quickslice's internal OAuth stack (default)
  Internal
  /// Use AIP as the auth provider
  Aip(base_url: String)
}
