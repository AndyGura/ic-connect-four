// GamePlugin for Connect Four — the only game-specific client code besides
// the 3D stage (stage.js), which draws the board itself. Action/View/Options
// mirror ../../src/ConnectFourRules.mo exactly. `legal()` is a cosmetic echo
// of that module's `validate`, `applyLocal` of its `resolve`.
//
// The board is 42 cells, row-major from the BOTTOM: index = row * 7 + col.
// In JS a cell decodes as `[]` (empty) or `[{ p1: null }]` / `[{ p2: null }]`,
// `nat` as bigint.

import { actionAttr, esc } from "@research-ag/duel-game-core/render.js";

export const COLS = 7;
export const ROWS = 6;

const SEAT_NAME = { p1: "Red", p2: "Yellow" };
const DIRECTIONS = [
  [0, 1],
  [1, 0],
  [1, 1],
  [1, -1],
];

const seatOf = (v) => Object.keys(v)[0];

/// The View in plain JS: `cells` of "p1" | "p2" | null, numbers for nats.
export function decodeGame(game) {
  const cells = game.board.map((c) => (c.length ? seatOf(c[0]) : null));
  const lm = game.lastMove.length ? game.lastMove[0] : null;
  return {
    cells,
    lastMove: lm && { col: Number(lm.col), row: Number(lm.row), seat: seatOf(lm.seat) },
    winLine: game.winLine.map(Number),
  };
}

export const discCount = (cells) => cells.filter((c) => c !== null).length;

/// Red is on turn after an even number of discs (the rules' `toMove`).
export const seatToMove = (cells) => (discCount(cells) % 2 === 0 ? "p1" : "p2");

/// The row a disc dropped into `col` lands on; null when it is full.
export function landingRow(cells, col) {
  for (let row = 0; row < ROWS; row++) if (cells[row * COLS + col] === null) return row;
  return null;
}

function legal(cells, col) {
  return col >= 0 && col < COLS && landingRow(cells, col) !== null;
}

/// Every line of four or more through (row, col) in `seat`'s colour, each
/// as its cell indices in order along the line.
export function linesThrough(cells, row, col, seat) {
  const at = (r, c) => (r < 0 || c < 0 || r >= ROWS || c >= COLS ? null : cells[r * COLS + c]);
  const lines = [];
  for (const [dr, dc] of DIRECTIONS) {
    let r = row;
    let c = col;
    while (at(r - dr, c - dc) === seat) {
      r -= dr;
      c -= dc;
    }
    const line = [];
    while (at(r, c) === seat) {
      line.push(r * COLS + c);
      r += dr;
      c += dc;
    }
    if (line.length >= 4) lines.push(line);
  }
  return lines;
}

/// winLine (a set of cells) split back into its straight lines, for drawing.
export function winSegments(cells, winLine) {
  const set = new Set(winLine);
  const seen = new Set();
  const segments = [];
  for (const i of winLine) {
    const row = Math.floor(i / COLS);
    const col = i % COLS;
    for (const line of linesThrough(cells, row, col, cells[i])) {
      if (!line.every((j) => set.has(j))) continue;
      const key = `${line[0]}-${line[line.length - 1]}`;
      if (seen.has(key)) continue;
      seen.add(key);
      segments.push(line);
    }
  }
  return segments;
}

const chip = (seat) => `<span class="c4-chip c4-chip-${seat}" aria-hidden="true"></span>`;

function lastMoveText(g, mySeat, over) {
  if (!g.lastMove) return "The board is empty — Red drops first.";
  const who = g.lastMove.seat === mySeat ? "You" : SEAT_NAME[g.lastMove.seat];
  const where = `column ${g.lastMove.col + 1}`;
  if (over && g.winLine.length > 0) {
    return `${chip(g.lastMove.seat)} ${who === "You" ? "Your" : `${who}'s`} winning drop: ${where}.`;
  }
  return `${chip(g.lastMove.seat)} ${who} dropped into ${where}.`;
}

// The board in 2D, top row first: what a screen reader gets, and what is
// shown when the 3D stage cannot start (no WebGL).
function miniBoard(g) {
  const last = g.lastMove ? g.lastMove.row * COLS + g.lastMove.col : -1;
  const win = new Set(g.winLine);
  let cells = "";
  for (let row = ROWS - 1; row >= 0; row--) {
    for (let col = 0; col < COLS; col++) {
      const i = row * COLS + col;
      const seat = g.cells[i];
      const cls = ["c4-cell", seat ? `c4-cell-${seat}` : "", i === last ? "c4-cell-last" : "", win.has(i) ? "c4-cell-win" : ""];
      const label = seat ? SEAT_NAME[seat] : "empty";
      cells += `<span class="${cls.join(" ").trim()}" role="gridcell" aria-label="${label}"></span>`;
    }
  }
  return `<div class="c4-mini" role="grid" aria-label="Board, top row first">${cells}</div>`;
}

export const plugin = {
  idlTypes({ IDL }) {
    const Seat = IDL.Variant({ p1: IDL.Null, p2: IDL.Null });
    const Action = IDL.Variant({ drop: IDL.Record({ col: IDL.Nat }) });
    const LastMove = IDL.Record({ col: IDL.Nat, row: IDL.Nat, seat: Seat });
    // Nothing is hidden: the view is the whole state.
    const View = IDL.Record({
      board: IDL.Vec(IDL.Opt(Seat)),
      lastMove: IDL.Opt(LastMove),
      winLine: IDL.Vec(IDL.Nat),
    });
    const Options = IDL.Record({});
    return { Action, View, Options };
  },

  seatLabel(seat) {
    return SEAT_NAME[seat];
  },

  // The board itself is the 3D stage beside this panel; here, who is who,
  // whose turn it is, and the most recent drop in words (live and in the
  // debrief, where `yourTurn` is undefined).
  renderBoard(gameState, mySeat, oppSeat, yourTurn) {
    const g = decodeGame(gameState);
    const over = yourTurn === undefined;
    const onTurn = over ? null : seatToMove(g.cells);
    const player = (seat) => `
      <div class="c4-player${seat === onTurn ? " c4-on-turn" : ""}">
        ${chip(seat)}
        <span class="c4-player-name">${esc(SEAT_NAME[seat])}</span>
        <span class="c4-player-tag">${seat === mySeat ? "You" : "Opponent"}</span>
      </div>`;
    return `
      <div class="c4-players">${player("p1")}${player("p2")}</div>
      <p class="c4-last">${lastMoveText(g, mySeat, over)}</p>
      ${miniBoard(g)}`;
  },

  // Only called while it's mySeat's turn: one button per column, full ones
  // disabled. Clicking (or tapping) the 3D board sends the same moves.
  renderActions(gameState, mySeat) {
    const g = decodeGame(gameState);
    const buttons = [];
    for (let col = 0; col < COLS; col++) {
      const ok = legal(g.cells, col);
      buttons.push(
        `<button type="button" class="c4-col c4-col-${mySeat}" data-col="${col}" ${actionAttr({ drop: { col } })} ${ok ? "" : "disabled"} title="${ok ? `Drop into column ${col + 1}` : "This column is full"}">${col + 1}</button>`,
      );
    }
    return `
      <p class="c4-hint">Your move — click a column on the board, press 1–7, or:</p>
      <div class="c4-cols">${buttons.join("")}</div>`;
  },

  // The board once mySeat's disc lands, drawn while the submit is in flight.
  applyLocal(gameState, mySeat, move) {
    const col = Number(move?.drop?.col);
    const g = decodeGame(gameState);
    if (!legal(g.cells, col)) return null;
    const row = landingRow(g.cells, col);
    const at = row * COLS + col;
    const cells = g.cells.slice();
    cells[at] = mySeat;
    const winLine = [...new Set(linesThrough(cells, row, col, mySeat).flat())].sort((a, b) => a - b);
    return {
      board: gameState.board.map((c, i) => (i === at ? [{ [mySeat]: null }] : c)),
      lastMove: [{ col: BigInt(col), row: BigInt(row), seat: { [mySeat]: null } }],
      winLine: winLine.map(BigInt),
    };
  },
};
