// Summon shim bootstrap — injects a minimal React-shaped createElement + @raycast/api surface.
// Runs inside a per-extension JSC context. No Node, no filesystem, no process.

var __summon = globalThis.__summon || {};
globalThis.__summon = __summon;

// --- minimal React createElement (no reconciler DOM; pure virtual tree) ---
var React = {
  createElement: function (type, props) {
    var children = [];
    for (var i = 2; i < arguments.length; i++) {
      var c = arguments[i];
      if (c === null || c === undefined || c === false) continue;
      if (Array.isArray(c)) {
        for (var j = 0; j < c.length; j++) children.push(c[j]);
      } else {
        children.push(c);
      }
    }
    var p = props ? Object.assign({}, props) : {};
    // Functions (event handlers) cannot cross the bridge as JSON — strip; host uses action ids.
    var clean = {};
    for (var k in p) {
      if (!Object.prototype.hasOwnProperty.call(p, k)) continue;
      if (typeof p[k] === "function") {
        clean[k] = "[Function]";
      } else {
        clean[k] = p[k];
      }
    }
    var typeName = typeof type === "function" ? (type.displayName || type.name || "Component") : String(type);
    // If type is a function component, invoke it.
    if (typeof type === "function" && !type.__isRaycastHost) {
      return type(Object.assign({}, clean, { children: children }));
    }
    return { type: typeName, props: clean, children: children };
  },
  Fragment: function Fragment(props) {
    return { type: "Fragment", props: {}, children: (props && props.children) || [] };
  }
};
globalThis.React = React;

// --- LocalStorage (namespaced; backed by host bridge) ---
var LocalStorage = {
  getItem: function (key) {
    return __summon.hostStorageGet(String(key));
  },
  setItem: function (key, value) {
    __summon.hostStorageSet(String(key), String(value));
  },
  removeItem: function (key) {
    __summon.hostStorageRemove(String(key));
  },
  clear: function () {
    __summon.hostStorageClear();
  },
  allItems: function () {
    return __summon.hostStorageAll();
  }
};

// --- fetch (host-bridged; entitlement-gated in Swift) ---
function fetch(url, init) {
  var body = init && init.body != null ? String(init.body) : null;
  var method = (init && init.method) || "GET";
  var headers = (init && init.headers) || {};
  var raw = __summon.hostFetch(String(url), String(method), JSON.stringify(headers), body);
  var parsed = JSON.parse(raw);
  return {
    ok: !!parsed.ok,
    status: parsed.status || 0,
    statusText: parsed.statusText || "",
    json: function () { return parsed.json != null ? parsed.json : null; },
    text: function () { return parsed.text != null ? String(parsed.text) : ""; }
  };
}
globalThis.fetch = fetch;

// --- @raycast/api host components ---
function mark(fn, name) {
  fn.__isRaycastHost = true;
  fn.displayName = name;
  fn.name = name;
  return fn;
}

function host(name) {
  return mark(function (props) {
    var children = props && props.children;
    var list = [];
    if (children !== undefined && children !== null) {
      if (Array.isArray(children)) list = children;
      else list = [children];
    }
    var p = Object.assign({}, props || {});
    delete p.children;
    return { type: name, props: p, children: list };
  }, name);
}

var List = host("List");
List.Item = host("List.Item");
List.Section = host("List.Section");
List.EmptyView = host("List.EmptyView");
List.Dropdown = host("List.Dropdown");
List.Dropdown.Item = host("List.Dropdown.Item");

var Detail = host("Detail");
Detail.Metadata = host("Detail.Metadata");
Detail.Metadata.Label = host("Detail.Metadata.Label");

var Form = host("Form");
Form.TextField = host("Form.TextField");
Form.TextArea = host("Form.TextArea");
Form.PasswordField = host("Form.PasswordField");
Form.Checkbox = host("Form.Checkbox");
Form.Dropdown = host("Form.Dropdown");
Form.Dropdown.Item = host("Form.Dropdown.Item");
Form.Description = host("Form.Description");
Form.Separator = host("Form.Separator");

var ActionPanel = host("ActionPanel");
ActionPanel.Section = host("ActionPanel.Section");
ActionPanel.Submenu = host("ActionPanel.Submenu");

var Action = host("Action");
Action.Push = host("Action.Push");
Action.CopyToClipboard = host("Action.CopyToClipboard");
Action.OpenInBrowser = host("Action.OpenInBrowser");
Action.SubmitForm = host("Action.SubmitForm");
Action.Style = { Regular: "regular", Destructive: "destructive" };

function showToast(options) {
  __summon.hostShowToast(JSON.stringify(options || {}));
  return Promise.resolve();
}

function getPreferenceValues() {
  return __summon.hostPreferences();
}

function getSelectedText() {
  return __summon.hostSelectedText();
}

var environment = {
  isDevelopment: false,
  commandName: __summon.commandName || "",
  extensionName: __summon.extensionName || ""
};

var Icon = new Proxy({}, {
  get: function (_t, prop) { return "Icon." + String(prop); }
});

var Color = new Proxy({}, {
  get: function (_t, prop) { return "Color." + String(prop); }
});

// CommonJS-shaped module table for require()
var __modules = {
  "react": { exports: React },
  "@raycast/api": {
    exports: {
      List: List,
      Detail: Detail,
      Form: Form,
      ActionPanel: ActionPanel,
      Action: Action,
      showToast: showToast,
      getPreferenceValues: getPreferenceValues,
      getSelectedText: getSelectedText,
      LocalStorage: LocalStorage,
      environment: environment,
      Icon: Icon,
      Color: Color,
      // React re-export convenience used by some templates
      React: React
    }
  }
};

function require(id) {
  if (__modules[id]) return __modules[id].exports;
  // Sandbox: no filesystem, no node builtins
  throw new Error("SummonShim: require('" + id + "') is not allowed in the sandbox");
}
globalThis.require = require;

// module.exports support for CommonJS entry files
var module = { exports: {} };
globalThis.module = module;
globalThis.exports = module.exports;

// Capture last toast / side effects for fixtures
__summon._toasts = [];
__summon.hostShowToast = __summon.hostShowToast || function (s) {
  __summon._toasts.push(JSON.parse(s));
};

// Serialize a virtual tree to JSON for the Swift bridge
function __summon_serialize(node) {
  if (node === null || node === undefined || node === false) return null;
  if (typeof node === "string" || typeof node === "number" || typeof node === "boolean") {
    return { type: "Text", props: { value: node }, children: [] };
  }
  if (Array.isArray(node)) {
    return { type: "Fragment", props: {}, children: node.map(__summon_serialize).filter(function (x) { return x; }) };
  }
  var children = (node.children || []).map(__summon_serialize).filter(function (x) { return x; });
  var props = {};
  var src = node.props || {};
  for (var k in src) {
    if (!Object.prototype.hasOwnProperty.call(src, k)) continue;
    var v = src[k];
    if (typeof v === "function") props[k] = "[Function]";
    else if (v === null || v === undefined) continue;
    else props[k] = v;
  }
  return { type: node.type || "Unknown", props: props, children: children };
}
globalThis.__summon_serialize = __summon_serialize;

function __summon_render(commandExport) {
  var element;
  if (typeof commandExport === "function") {
    element = commandExport({});
  } else if (commandExport && typeof commandExport.default === "function") {
    element = commandExport.default({});
  } else if (commandExport && commandExport.type) {
    element = commandExport;
  } else {
    throw new Error("SummonShim: command export is not a renderable component");
  }
  return JSON.stringify(__summon_serialize(element));
}
globalThis.__summon_render = __summon_render;
