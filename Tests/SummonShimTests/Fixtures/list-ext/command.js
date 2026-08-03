// Synthetic store-style List extension (Raycast API surface).
var api = require("@raycast/api");
var List = api.List;
var ActionPanel = api.ActionPanel;
var Action = api.Action;
var React = require("react");

function Command() {
  return React.createElement(
    List,
    { searchBarPlaceholder: "Search items" },
    React.createElement(List.Item, {
      title: "Invoice Q3",
      subtitle: "PDF",
      accessories: [{ text: "2d ago" }],
      actions: React.createElement(
        ActionPanel,
        null,
        React.createElement(Action, { title: "Open", id: "open" })
      )
    }),
    React.createElement(List.Item, {
      title: "Receipt 1042",
      subtitle: "PNG"
    })
  );
}

module.exports = Command;
