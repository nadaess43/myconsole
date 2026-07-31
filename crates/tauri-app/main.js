import { listen } from "@tauri-apps/api/event";

/** @type {HTMLUListElement} */
const list = document.getElementById("cartridge-list");

/** @type {Map<string, HTMLLIElement>} */
const items = new Map();

function clearEmpty() {
  const empty = list.querySelector(".empty");
  if (empty) empty.remove();
}

function addCartridge({ cartridgeId, title, drive, folder }) {
  clearEmpty();
  const li = document.createElement("li");
  li.id = `cartridge-${cartridgeId}`;
  li.innerHTML = `
    <span class="marker inserted">+</span>
    <span class="title">${escapeHtml(title)}</span>
    <span class="info">${drive}:\\${folder} — ${cartridgeId.slice(0, 8)}</span>
  `;
  items.set(cartridgeId, li);
  list.appendChild(li);
}

function removeCartridge({ cartridgeId }) {
  const li = items.get(cartridgeId);
  if (li) {
    li.querySelector(".marker").className = "marker removed";
    li.querySelector(".marker").textContent = "−";
    li.style.opacity = "0.4";
  }
}

function escapeHtml(text) {
  const div = document.createElement("div");
  div.textContent = text;
  return div.innerHTML;
}

async function start() {
  console.log("[frontend] Waiting for cartridge events...");

  await listen("cartridge-inserted", ({ payload }) => {
    console.log("[frontend] inserted:", payload);
    addCartridge(payload);
  });

  await listen("cartridge-removed", ({ payload }) => {
    console.log("[frontend] removed:", payload);
    removeCartridge(payload);
  });

  console.log("[frontend] Ready.");
}

start();
