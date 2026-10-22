// The two default screens Connect Four words in its own voice, passed to
// `start({ screens })`. Both keep the default shell's `data-*` attributes
// and form inputs, so its click handling, access-code prompt and create-
// table form all work unchanged.

import { debriefVerdict, esc, renderTableRow, tag } from "@research-ag/duel-game-core/render.js";

const chip = (seat) => `<span class="c4-chip c4-chip-${seat}" aria-hidden="true"></span>`;

function browsing(v, plugin) {
  const seatBtn = (seat, note) => `
    <button class="seat c4-seat" data-create-table="${seat}">
      ${chip(seat)}
      <span class="c4-seat-text">
        <span class="seat-label">Play ${esc(plugin.seatLabel(seat))}</span>
        <span class="muted">${note}</span>
      </span>
    </button>`;
  return `
    <h2>Pull up a chair</h2>
    <section class="create-table">
      <h3>Start a table</h3>
      <div class="option-group">
        <span class="option-group-label">Who may join</span>
        <label><input type="radio" name="table-visibility" value="open" checked /> Anyone</label>
        <label><input type="radio" name="table-visibility" value="code" /> A friend with the access code</label>
        <input type="text" id="create-code" class="table-code-input" placeholder="access code" hidden />
      </div>
      <div class="seats">
        ${seatBtn("p1", "drops first")}
        ${seatBtn("p2", "drops second")}
      </div>
    </section>
    <section class="open-tables">
      <h3>Tables</h3>
      ${
        v.tables.length === 0
          ? `<p class="muted">No tables yet — start one and share this page.</p>`
          : v.tables.map((r) => renderTableRow(r, plugin)).join("")
      }
    </section>`;
}

// The final board is the 3D stage; `renderBoard` adds who was who and the
// deciding drop in words.
function debrief(v, plugin) {
  const mySeat = tag(v.seat);
  const oppSeat = mySeat === "p1" ? "p2" : "p1";
  const { title, outcome } = debriefVerdict(v.end, mySeat);
  const discs = Number(v.steps);
  return `
    <h2 class="verdict ${outcome}">${esc(title)}</h2>
    <p class="muted">${discs} disc${discs === 1 ? "" : "s"} dropped.</p>
    <div class="board">${plugin.renderBoard(v.finalGame, mySeat, oppSeat)}</div>
    <p class="c4-end-actions">
      <button data-rematch class="primary">Rematch</button>
      <button data-leave class="ghost">Return to lobby</button>
    </p>`;
}

export const screens = { browsing, debrief };
