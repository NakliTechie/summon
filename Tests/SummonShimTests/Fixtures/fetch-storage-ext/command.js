// Synthetic extension that uses LocalStorage + fetch (Raycast API surface).
var api = require("@raycast/api");
var List = api.List;
var LocalStorage = api.LocalStorage;
var React = require("react");

// Side effects at module load (common pattern for small commands).
LocalStorage.setItem("visited", "1");
var prior = LocalStorage.getItem("count") || "0";
var next = String(Number(prior) + 1);
LocalStorage.setItem("count", next);

var remoteTitle = "offline";
try {
  var res = fetch("https://example.test/v1/status", { method: "GET" });
  if (res.ok) {
    var body = res.json();
    if (body && body.title) remoteTitle = String(body.title);
    LocalStorage.setItem("remoteTitle", remoteTitle);
  }
} catch (e) {
  remoteTitle = "error";
}

function Command() {
  return React.createElement(
    List,
    null,
    React.createElement(List.Item, {
      title: remoteTitle,
      subtitle: "count=" + LocalStorage.getItem("count")
    })
  );
}

module.exports = Command;
