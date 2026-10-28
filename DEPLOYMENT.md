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

On Render, the export script downloads the pinned Godot 4.7.2 binary and Web templates if needed. The generated `web-build/` directory is ignored by Git.

## Render Static Site

Create a Render **Static Site** from the same repository. Set the build command to `python3 tools/export_web.py --require-production-url` and the publish directory to `web-build`. Before deploying, add the Static Site environment variable `SLAVE_CARD_SERVER_URL` with the public URL of the Web Service, for example `wss://slave-card-server.onrender.com`. `render.yaml` includes this configuration; Render prompts for the URL because it is marked `sync: false`.

The export script temporarily writes this URL into `config/server_url.cfg` for the web build and restores the tracked local-development value afterward. The production URL is therefore baked into the exported client, while local runs continue to use `ws://127.0.0.1:10000`.
