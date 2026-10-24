import {Socket} from "/assets/phoenix/phoenix.mjs";
import {LiveSocket} from "/assets/live/phoenix_live_view.esm.js";
const csrfToken = document.querySelector('meta[name="csrf-token"]').content;
const liveSocket = new LiveSocket("/live", Socket, {params: {_csrf_token: csrfToken}});
liveSocket.connect();
