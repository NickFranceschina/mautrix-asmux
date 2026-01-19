# mautrix-asmux

A Matrix Application Service Proxy and Multiplexer.

> **Note**: This project powered Beeper's infrastructure from 2020-2022. It is no longer actively maintained by Beeper, but remains functional with modern mautrix bridges.

## What is asmux?

asmux solves a fundamental problem with Matrix bridges: **each bridge typically requires its own Application Service registration with the homeserver**. This becomes unmanageable when you have many users, each running multiple bridges.

asmux acts as a single Application Service that multiplexes many bridges behind it. The homeserver only knows about one appservice (asmux), while asmux dynamically provisions and routes traffic to individual bridge instances.

```mermaid
graph LR
    subgraph "User's Home Network"
        WA[mautrix-whatsapp]
        IG[mautrix-instagram]
        FB[mautrix-facebook]
    end

    subgraph "Server"
        ASMUX[mautrix-asmux]
        HS[Synapse]
    end

    WA -->|WebSocket| ASMUX
    IG -->|WebSocket| ASMUX
    FB -->|WebSocket| ASMUX
    ASMUX -->|Single AS Registration| HS
```

## Key Features

- **Single Registration**: One appservice registration handles unlimited bridges
- **Dynamic Provisioning**: Create/delete bridge registrations via API
- **WebSocket Support**: Bridges can connect via WebSocket (ideal for NAT/firewall traversal)
- **HTTP Push**: Traditional HTTP mode where asmux pushes events to bridges
- **Namespace Isolation**: Each user's bridges get isolated Matrix ID namespaces
- **MSC2190 Implementation**: Appservice ping endpoint support

## Architecture

### Namespace Partitioning

Each bridge gets a unique namespace based on owner and prefix:

```text
@_{owner}_{prefix}_{localpart}:{server}
```

For example, user `alice` running a `whatsapp` bridge:

- Bridge bot: `@_alice_whatsapp_bot:example.com`
- Bridged users: `@_alice_whatsapp_12025551234:example.com`
- Aliases: `#_alice_whatsapp_portal123:example.com`

### Connection Modes

```mermaid
graph TB
    subgraph "HTTP Push Mode"
        HS1[Homeserver] -->|Events| ASMUX1[asmux]
        ASMUX1 -->|HTTP POST| BRIDGE1[Bridge]
    end

    subgraph "WebSocket Mode"
        HS2[Homeserver] -->|Events| ASMUX2[asmux]
        BRIDGE2[Bridge] -->|WebSocket| ASMUX2
        ASMUX2 -.->|Events via WS| BRIDGE2
    end
```

**HTTP Push**: asmux forwards events to bridges via HTTP POST. Requires bridges to be reachable from asmux.

**WebSocket**: Bridges connect to asmux via WebSocket at `/_matrix/client/unstable/fi.mau.as_sync`. Events are pushed through the WebSocket connection. Ideal for bridges behind NAT/firewalls.

### Data Flow

```mermaid
sequenceDiagram
    participant Client as Matrix Client
    participant HS as Homeserver
    participant ASMUX as mautrix-asmux
    participant Redis
    participant Bridge as Bridge (WebSocket)

    Note over Bridge,ASMUX: Bridge connects via WebSocket
    Bridge->>ASMUX: WebSocket connect with as_token
    ASMUX->>Redis: Cache bridge connection

    Note over Client,Bridge: Incoming message from Matrix
    Client->>HS: Send message to portal room
    HS->>ASMUX: AS Transaction (events)
    ASMUX->>Redis: Lookup room -> bridge mapping
    ASMUX->>Bridge: Forward event via WebSocket
    Bridge-->>ASMUX: Acknowledge

    Note over Client,Bridge: Outgoing message from bridge
    Bridge->>ASMUX: CS API request (via WebSocket)
    ASMUX->>HS: Proxied CS API request
    HS-->>ASMUX: Response
    ASMUX-->>Bridge: Response via WebSocket
```

## Setup

### Requirements

- PostgreSQL database
- Redis server
- Python 3.11+ (or Docker)

### Docker

```bash
docker build -t mautrix-asmux .

docker run -v /path/to/data:/data mautrix-asmux
```

### Configuration

1. Copy the example config:

   ```bash
   cp mautrix_asmux/example-config.yaml /data/config.yaml
   ```

2. Edit the config file with your settings:

   ```yaml
   homeserver:
     domain: example.com
     address: http://synapse:8008

   appservice:
     address: http://asmux:29326
     id: asmux
     namespace:
       prefix: _
       exclusive: true

   mux:
     hostname: 0.0.0.0
     port: 29326
     database: postgres://user:pass@postgres/asmux
     redis: redis://redis:6379
     public_address: https://asmux.example.com
     shared_secret: your-secret-here
   ```

3. Generate the registration file:

   ```bash
   python3 -m mautrix_asmux -g -c /data/config.yaml
   ```

4. Add the registration to Synapse's `homeserver.yaml`:

   ```yaml
   app_service_config_files:
     - /path/to/asmux-registration.yaml
   ```

5. Start asmux:

   ```bash
   python3 -m mautrix_asmux -c /data/config.yaml
   ```

## Management API

### Authentication

All management API endpoints require authentication via Bearer token:

```text
Authorization: Bearer <shared_secret>
```

Or for user-scoped endpoints, a Matrix access token via `/_matrix/asmux/mxauth/` prefix.

### Endpoints

#### Provision a Bridge

```http
PUT /_matrix/asmux/appservice/{owner}/{prefix}
Content-Type: application/json

{
    "address": "http://bridge:29318",  // For HTTP push mode
    "push": true,                       // true for HTTP, false for WebSocket
    "bot": "bot"                        // Bot localpart suffix (default: "bot")
}
```

**WebSocket mode** (bridge connects to asmux):

```json
{
    "push": false
}
```

**Response**: Returns a registration file for the bridge:

```json
{
    "id": "uuid-here",
    "as_token": "token-for-bridge",
    "hs_token": "token-from-hs",
    "namespaces": { ... },
    "sender_localpart": "_alice_whatsapp_bot",
    "url": "http://bridge:29318"
}
```

#### Get Bridge Registration

```http
GET /_matrix/asmux/appservice/{owner}/{prefix}
```

#### Delete Bridge

```http
DELETE /_matrix/asmux/appservice/{owner}/{prefix}
```

#### Ping Bridge

```http
POST /_matrix/asmux/appservice/{owner}/{prefix}/ping
```

#### Get/Create User

```http
GET /_matrix/asmux/user/{id}?create=true
PUT /_matrix/asmux/user/{id}
```

## Bridge Configuration

### mautrix-go Bridges (v2)

Modern mautrix bridges (whatsapp, signal, etc.) have native asmux support:

```yaml
homeserver:
    address: https://asmux.example.com
    domain: example.com
    software: asmux          # Enable asmux mode
    websocket: true          # Use WebSocket connection

appservice:
    id: <from-registration>
    as_token: <from-registration>
    hs_token: <from-registration>
```

The bridge will automatically connect via WebSocket to:

```text
wss://asmux.example.com/_matrix/client/unstable/fi.mau.as_sync
```

### Token Format

Bridge tokens follow the format: `{uuid}-{as_token}`

The UUID prefix identifies the bridge instance, allowing asmux to route requests correctly.

## Development

### Project Structure

```text
mautrix_asmux/
├── api/
│   ├── as_http.py        # HTTP push to bridges
│   ├── as_proxy.py       # AS transaction handling
│   ├── as_websocket.py   # WebSocket connections from bridges
│   ├── cs_proxy.py       # Client-Server API proxy
│   └── management_api.py # Management endpoints
├── database/             # PostgreSQL models
├── config.py             # Configuration handling
└── server.py             # Main server setup
```

### Dependencies

- `aiohttp` - HTTP server/client
- `asyncpg` - PostgreSQL driver
- `redis` - Redis for caching and coordination
- `mautrix` - Matrix library

## License

Copyright (C) 2020-2022 Beeper, Inc. All rights reserved.
