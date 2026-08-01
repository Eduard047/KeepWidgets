const TOKEN = "d62c364d1ba74093a028ecb6662e426919f0250931d94d1a";

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (!message || message.type !== "KEEP_WIDGET_IMPORT") return;

  fetch(`http://127.0.0.1:43821/import?token=${TOKEN}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json"
    },
    body: JSON.stringify(message.payload)
  })
    .then(async response => {
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      return response.json();
    })
    .then(() => sendResponse({ ok: true }))
    .catch(error => sendResponse({ ok: false, error: String(error.message || error) }));

  return true;
});
