// Synthetic Form extension (Raycast API surface).
var api = require("@raycast/api");
var Form = api.Form;
var ActionPanel = api.ActionPanel;
var Action = api.Action;
var React = require("react");

function Command() {
  return React.createElement(
    Form,
    {
      actions: React.createElement(
        ActionPanel,
        null,
        React.createElement(Action.SubmitForm, { title: "Save", id: "save" })
      )
    },
    React.createElement(Form.TextField, {
      id: "title",
      title: "Title",
      placeholder: "Name this"
    }),
    React.createElement(Form.TextArea, {
      id: "body",
      title: "Body"
    }),
    React.createElement(Form.Checkbox, {
      id: "pin",
      label: "Pin",
      defaultValue: false
    })
  );
}

module.exports = Command;
