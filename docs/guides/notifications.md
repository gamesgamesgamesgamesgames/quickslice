# Notifications

Notifications show records that mention the authenticated user. When someone likes your post, follows you, or references your DID in any record, it appears in your notifications.

## How It Works

The `notifications` query searches all records for your DID. It returns matches where:
- The record's JSON contains your DID (as a URI or raw DID)
- The record was authored by someone else (self-mentions excluded)

The server identifies you from your access token. Authentication is required.

## Basic Query

```graphql
query {
  notifications(first: 20) {
    edges {
      node {
        __typename
        ... on AppBskyFeedLike {
          uri
          did
          createdAt
        }
        ... on AppBskyGraphFollow {
          uri
          did
          createdAt
        }
      }
      cursor
    }
    pageInfo {
      hasNextPage
      endCursor
    }
  }
}
```

The `node` is a union type containing all record types in your schema. Use inline fragments (`... on TypeName`) to access type-specific fields.

## Response Example

When Alice likes your post and Bob follows you:

```json
{
  "data": {
    "notifications": {
      "edges": [
        {
          "node": {
            "__typename": "AppBskyGraphFollow",
            "uri": "at://did:plc:bob/app.bsky.graph.follow/3k2yab7",
            "did": "did:plc:bob",
            "createdAt": "2024-01-03T12:00:00Z"
          },
          "cursor": "eyJ..."
        },
        {
          "node": {
            "__typename": "AppBskyFeedLike",
            "uri": "at://did:plc:alice/app.bsky.feed.like/3k2xz9m",
            "did": "did:plc:alice",
            "createdAt": "2024-01-02T10:30:00Z"
          },
          "cursor": "eyJ..."
        }
      ],
      "pageInfo": {
        "hasNextPage": false,
        "endCursor": "eyJ..."
      }
    }
  }
}
```

Results are sorted newest-first by rkey (TID).

## Filtering by Collection

Filter to specific record types using the `collections` argument:

```graphql
query {
  notifications(collections: [APP_BSKY_FEED_LIKE], first: 20) {
    edges {
      node {
        ... on AppBskyFeedLike {
          uri
          did
        }
      }
    }
  }
}
```

Collection names use the enum format: `app.bsky.feed.like` becomes `APP_BSKY_FEED_LIKE`.

Filter to multiple types:

```graphql
query {
  notifications(
    collections: [APP_BSKY_FEED_LIKE, APP_BSKY_GRAPH_FOLLOW]
    first: 20
  ) {
    # ...
  }
}
```

## Pagination

Use cursor-based pagination to fetch more results:

```graphql
query {
  notifications(first: 20, after: "eyJ...") {
    edges {
      node { __typename }
      cursor
    }
    pageInfo {
      hasNextPage
      endCursor
    }
  }
}
```

Pass `pageInfo.endCursor` as the `after` argument to fetch the next page.

## Real-time Updates

Subscribe to new notifications as they happen:

```graphql
subscription {
  notificationCreated {
    __typename
    ... on AppBskyFeedLike {
      uri
      did
      createdAt
    }
    ... on AppBskyGraphFollow {
      uri
      did
      createdAt
    }
  }
}
```

Filter to specific collections:

```graphql
subscription {
  notificationCreated(collections: [APP_BSKY_FEED_LIKE]) {
    ... on AppBskyFeedLike {
      uri
      did
    }
  }
}
```

See [Subscriptions](./subscriptions.md) for WebSocket connection details.

## Authentication Required

Notifications require authentication. Without a valid access token, the query returns an error.

Use the [Quickslice client SDK](./authentication.md#using-the-client-sdk) to handle authentication automatically.
