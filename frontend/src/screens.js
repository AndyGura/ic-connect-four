// The default screens Connect Four words in its own voice, passed to
// `start({ screens })`. All keep the default shell's `data-*` attributes
// and form inputs, so its click handling, access-code prompt and create-
// table form all work unchanged. `data-open-bots` opens the bot dialog
// (bots.js).

import { debriefVerdict, esc, renderStagingYou, renderTableRow, tag } from "@research-ag/duel-game-core/render.js";

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
    <section class="c4-bots">
      <h3>Play a bot</h3>
      <button type="button" class="c4-bots-open" data-open-bots>
        <span class="c4-bots-icon" aria-hidden="true">🤖</span>
        <span class="c4-seat-text">
          <span class="seat-label">Challenge a bot</span>
          <span class="muted">a computer player registered with this game</span>
        </span>
      </button>
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

// Waiting for an opponent: a bot may take the open seat — unless it is
// held for the last opponent (a Rematch against a bot re-invites it by
// itself).
function stagingYou(v, plugin) {
  const addBot = v.reservedForPartner
    ? ""
    : `<p class="c4-add-bot"><button type="button" class="ghost" data-open-bots>🤖 Add a bot to the open seat</button></p>`;
  return renderStagingYou(v, plugin) + addBot;
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

export const screens = { browsing, stagingYou, debrief };
