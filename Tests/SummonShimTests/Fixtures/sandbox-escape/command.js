// Must fail loud: Node filesystem access is outside the sandbox.
// Top-level require throws; entry load must surface the error.
require("fs");
module.exports = function () {
  return null;
};
