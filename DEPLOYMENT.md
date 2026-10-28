# Render deployment

## Local development

Run the project normally in Godot. Start the authoritative server with `res://scenes/server.tscn`; it binds to `0.0.0.0` and uses `PORT`, or `10000` when `PORT` is unset. The multiplayer menu defaults to `ws://127.0.0.1:10000`, which works with that local server. To use another local port, set `PORT` for the server and enter the matching `ws://127.0.0.1:<port>` address in the Host field.

## WebSocket server on Render

The root `Dockerfile` runs the authoritative server scene. Create a Render **Web Service** from this repository and choose **Docker** as its runtime. Keep the Dockerfile path as `./Dockerfile`; Render supplies `PORT` at runtime. The server listens on that port and binds publicly. Render terminates TLS, so clients connect using `wss://<service-name>.onrender.com`.

The same settings are described in `render.yaml`. The Web Service needs a plan that supports persistent WebSocket connections.

## Godot Web export

The project includes a `Web` export preset targeting `web-build/index.html`. Install Godot 4.7.2 and its matching export templates, then run:

```sh
python3 tools/export_web.py
```

The generated `web-build/` directory is committed to Git and served directly by Render. After gameplay or client changes, a developer must export the Web build locally and commit the updated `web-build/` files.

## Render Static Site

Create a Render **Static Site** from the same repository. Set the build command to `echo "Using committed Godot Web build"` and the publish directory to `web-build`. Render does not install Godot or export the project during deployment.

The export script temporarily writes `wss://slave-card-server.onrender.com` into `config/server_url.cfg` for the production Web build and restores the tracked local-development value afterward. The production URL is baked into the committed exported client, while local runs continue to use `ws://127.0.0.1:10000`. To refresh the production client, run `SLAVE_CARD_SERVER_URL=wss://slave-card-server.onrender.com python3 tools/export_web.py` on a machine with Godot 4.7.2 and its Web templates installed, then commit the updated `web-build/`.
