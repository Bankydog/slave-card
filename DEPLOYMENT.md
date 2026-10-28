# Render deployment

## Local development

Run the project normally in Godot. Start the authoritative server directly with `res://scenes/server.tscn`; it binds to `0.0.0.0` and uses `PORT`, or `10000` when `PORT` is unset. Native desktop clients default to `ws://127.0.0.1:10000`. To use another local port, set `PORT` for the server and configure the desktop client in `config/server_url.cfg`. The Docker container uses the proxy and an internal `GODOT_PORT` of `10001` instead.

## WebSocket server on Render

The root `Dockerfile` runs a small Node HTTP/WebSocket transport proxy and the authoritative Godot server. The proxy binds `0.0.0.0:$PORT`, serves HTTP 200 at `/` and `/health`, and forwards WebSocket upgrades on `/` to Godot at `127.0.0.1:10001`. Godot binds only to that loopback address and remains responsible for rooms, player state, game rules, turns, bots, card exchange, and gameplay state. Render terminates TLS, so the public client URL remains `wss://slave-card-server.onrender.com`.

The same settings are described in `render.yaml`: the server uses the Free plan, `/health` is the HTTP health check, and one instance is configured. Room and session state remains in process memory; horizontal scaling beyond one instance will require shared room/session state or routing changes. Render closes existing WebSocket connections when it replaces an instance, so clients need to reconnect after a deploy or restart.

## Godot Web export

The project includes a `Web` export preset targeting `web-build/index.html`. Install Godot 4.7.2 and its matching export templates, then run:

```sh
python3 tools/export_web.py
```

The generated `web-build/` directory is committed to Git and served directly by Render. After gameplay or client changes, a developer must export the Web build locally and commit the updated `web-build/` files.

## Render Static Site

Create a Render **Static Site** from the same repository. Set the build command to `echo "Using committed Godot Web build"` and the publish directory to `web-build`. Render does not install Godot or export the project during deployment.

Web clients always use `wss://slave-card-server.onrender.com`; `config/server_url.cfg` cannot override that URL. Native desktop clients use localhost by default and may use `config/server_url.cfg` for a different development server. To refresh the production client, run `SLAVE_CARD_SERVER_URL=wss://slave-card-server.onrender.com python3 tools/export_web.py` on a machine with Godot 4.7.2 and its Web templates installed, then commit the updated `web-build/`.
