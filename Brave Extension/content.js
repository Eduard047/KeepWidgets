(() => {
  if (window.__keepWidgetsImporterInstalled) return;
  window.__keepWidgetsImporterInstalled = true;

  const wordsToDrop = new Set([
    "Закріпити нотатку", "Відкріпити нотатку", "Нагадати мені", "Співавтор",
    "Додати зображення", "Архівувати", "Більше", "Закрити", "Назад",
    "Закрепить заметку", "Открепить заметку", "Напомнить", "Соавторы",
    "Добавить изображение", "Архивировать", "Ещё", "Закрыть",
    "Pin note", "Unpin note", "Remind me", "Collaborator", "Add image",
    "Archive", "More", "Close"
  ]);

  const host = document.createElement("div");
  host.id = "keep-widgets-importer-root";
  host.style.cssText = "position:fixed;right:22px;bottom:22px;z-index:2147483647;font-family:-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif";
  const shadow = host.attachShadow({ mode: "open" });
  shadow.innerHTML = `
    <style>
      *{box-sizing:border-box}
      button{font:600 13px -apple-system,BlinkMacSystemFont,Segoe UI,sans-serif}
      #launch{border:0;border-radius:999px;padding:11px 16px;background:#202124;color:#fff;box-shadow:0 4px 18px #0004;cursor:pointer}
      #launch:hover{background:#34363a}
      #panel{display:none;width:248px;margin-bottom:10px;padding:12px;border:1px solid #dadce0;border-radius:14px;background:#fff;color:#202124;box-shadow:0 8px 28px #0004}
      #panel.open{display:block}
      h3{font-size:14px;margin:0 0 4px}
      p{font-size:12px;line-height:1.35;color:#5f6368;margin:0 0 10px}
      #slots{display:grid;grid-template-columns:repeat(4,1fr);gap:6px}
      #slots button{height:38px;border:1px solid #dadce0;border-radius:9px;background:#fff;color:#202124;cursor:pointer}
      #slots button:hover{background:#fff4bd;border-color:#f5c400}
      #toast{display:none;margin-top:9px;padding:8px;border-radius:8px;background:#e6f4ea;color:#137333;font-size:12px}
      #toast.error{background:#fce8e6;color:#c5221f}
    </style>
    <div id="panel">
      <h3>Добавить как виджет</h3>
      <p>Откройте заметку и выберите номер плитки на рабочем столе.</p>
      <div id="slots"></div>
      <div id="toast"></div>
    </div>
    <button id="launch" type="button">▣ На рабочий стол</button>
  `;
  document.documentElement.appendChild(host);

  const launch = shadow.getElementById("launch");
  const panel = shadow.getElementById("panel");
  const slots = shadow.getElementById("slots");
  const toast = shadow.getElementById("toast");

  for (let slot = 1; slot <= 12; slot += 1) {
    const button = document.createElement("button");
    button.type = "button";
    button.textContent = String(slot);
    button.addEventListener("click", event => {
      event.preventDefault();
      event.stopPropagation();
      importCurrentNote(slot);
    });
    slots.appendChild(button);
  }

  launch.addEventListener("click", event => {
    event.preventDefault();
    event.stopPropagation();
    panel.classList.toggle("open");
    toast.style.display = "none";
  });

  document.addEventListener("keydown", event => {
    if (event.key === "Escape") panel.classList.remove("open");
  });

  function visible(element) {
    if (!element) return false;
    const rect = element.getBoundingClientRect();
    const style = getComputedStyle(element);
    return rect.width > 0 && rect.height > 0 && style.visibility !== "hidden" && style.display !== "none";
  }

  function findOpenNote() {
    const dialogs = [...document.querySelectorAll('[role="dialog"]')].filter(visible);
    if (dialogs.length) return dialogs.at(-1);

    if (location.hash.includes("NOTE")) {
      const editables = [...document.querySelectorAll('[contenteditable="true"]')].filter(visible);
      if (editables.length) {
        let node = editables.at(-1);
        for (let i = 0; i < 8 && node?.parentElement; i += 1) {
          if (node.getBoundingClientRect().width > 300 && node.getBoundingClientRect().height > 150) return node;
          node = node.parentElement;
        }
      }
    }
    return null;
  }

  function cleanText(text) {
    const lines = String(text || "")
      .split(/\n+/)
      .map(line => line.trim())
      .filter(Boolean)
      .filter(line => !wordsToDrop.has(line));
    return [...new Set(lines)].join("\n").trim();
  }

  function labelOf(element) {
    return `${element.getAttribute("aria-label") || ""} ${element.getAttribute("data-placeholder") || ""}`.toLowerCase();
  }

  function extractNote(root) {
    const editables = [...root.querySelectorAll('[contenteditable="true"], textarea, input')]
      .filter(visible)
      .map(element => ({
        element,
        label: labelOf(element),
        text: cleanText(element.innerText || element.value || element.textContent)
      }))
      .filter(item => item.text);

    const titleWords = ["title", "назва", "название", "заголов"];
    const bodyWords = ["note", "приміт", "нотат", "замет", "текст"];
    let titleItem = editables.find(item => titleWords.some(word => item.label.includes(word)));
    let bodyItem = editables.find(item => bodyWords.some(word => item.label.includes(word)) && item !== titleItem);

    if (!titleItem && editables.length > 1 && editables[0].text.length <= 500) titleItem = editables[0];
    if (!bodyItem) bodyItem = editables.find(item => item !== titleItem);

    const checkedRows = [...root.querySelectorAll('[role="checkbox"]')]
      .filter(visible)
      .map(checkbox => {
        const row = checkbox.closest('[role="listitem"]') || checkbox.parentElement?.parentElement || checkbox.parentElement;
        const text = cleanText(row?.innerText || "").replace(/\n/g, " ");
        if (!text) return "";
        return `${checkbox.getAttribute("aria-checked") === "true" ? "☑" : "☐"} ${text}`;
      })
      .filter(Boolean);

    let title = titleItem?.text || "Без названия";
    let body = checkedRows.length ? checkedRows.join("\n") : (bodyItem?.text || "");

    if (!body) {
      const fallback = cleanText(root.innerText)
        .split("\n")
        .filter(line => line !== title)
        .join("\n");
      body = fallback;
    }

    title = title.slice(0, 500);
    body = body.slice(0, 50000);

    let color = "#FFF1A8";
    let node = root;
    for (let i = 0; i < 6 && node; i += 1, node = node.parentElement) {
      const rgb = getComputedStyle(node).backgroundColor.match(/rgba?\((\d+),\s*(\d+),\s*(\d+)/);
      if (!rgb) continue;
      const [r, g, b] = rgb.slice(1).map(Number);
      if ((r > 245 && g > 245 && b > 245) || (r < 45 && g < 45 && b < 45)) continue;
      color = `#${[r, g, b].map(value => value.toString(16).padStart(2, "0")).join("")}`.toUpperCase();
      break;
    }

    return { title, body, url: location.href, color };
  }

  function showToast(message, isError = false) {
    toast.textContent = message;
    toast.classList.toggle("error", isError);
    toast.style.display = "block";
  }

  function importCurrentNote(slot) {
    const noteRoot = findOpenNote();
    if (!noteRoot) {
      showToast("Сначала откройте нужную заметку Keep.", true);
      return;
    }

    const note = extractNote(noteRoot);
    chrome.runtime.sendMessage({
      type: "KEEP_WIDGET_IMPORT",
      payload: { slot, ...note }
    }, response => {
      if (chrome.runtime.lastError) {
        showToast("Не удалось связаться с расширением Brave.", true);
      } else if (!response?.ok) {
        showToast("Запустите приложение Keep Widgets на Mac.", true);
      } else {
        showToast(`Готово: заметка отправлена в виджет Keep ${slot}.`);
        setTimeout(() => panel.classList.remove("open"), 1600);
      }
    });
  }
})();
