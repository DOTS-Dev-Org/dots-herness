// Global apply(harness) is the entry point.
function apply(h) {
  h.prompt("js:note", 40, "JS Panel example is mounted.");

  h.tool("js:reverse", "reverse a string", function (args) {
    return (args.text || "").split("").reverse().join("");
  });

  h.on("js/ping", function (payload) {
    h.emit("js/pong", "got " + payload);
  });

  // Declarative panel described as JSON — rendered by the same SwiftUI renderer.
  h.panel("conversation.composer.accessory", "main", 10, "JS Panel", {
    type: "vstack",
    children: [
      { type: "text", text: "Hello from JavaScript" },
      { type: "button", label: "Ping", tool: "js:reverse", args: { text: "abc" } }
    ]
  });
}
