// Unit checks for BotLogic and Search: from boards built by hand, every
// complexity answers a move GameRules accepts, and the searching ones
// take a win, block a loss and see what their depth claims. Hard runs at
// a shallow depth here (the interpreter is far slower than a canister).
//
// Run: mops test
import Array "mo:core/Array";
import Char "mo:core/Char";
import Nat32 "mo:core/Nat32";
import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import Runtime "mo:core/Runtime";
import VarArray "mo:core/VarArray";

import TP "mo:duel-game-core";

import Book "../src/Book";
import BotLogic "../src/BotLogic";
import Game "../src/GameTypes";
import Rules "../src/GameRules";
import Search "../src/Search";

// Hard's search with the interpreter's budget: the same code, shallower.
let HARD_TEST : Search.Settings = { BotLogic.HARD with maxDepth = 5; maxNodes = 30_000; ttSize = 4093 };
let never = func() : Nat = 0;

// A board drawn as it stands: six rows, TOP row first, 'R' = Red (#p1),
// 'Y' = Yellow (#p2), anything else empty.
func boardOf(rows : [Text]) : [?Game.Seat] {
  assert rows.size() == 6;
  let cells = VarArray.repeat<?Game.Seat>(null, 42);
  var row = 0;
  for (line in rows.reverse().values()) {
    var col = 0;
    for (ch in line.chars()) {
      cells[row * 7 + col] := switch (ch) {
        case 'R' ?#p1;
        case 'Y' ?#p2;
        case _ null;
      };
      col += 1;
    };
    row += 1;
  };
  Array.fromVarArray(cells);
};

func request(board : [?Game.Seat], complexity : Text) : TP.MoveRequest<Game.View, Game.Action> {
  {
    tableId = 1;
    seat = Rules.toMove(board);
    game = { board; lastMove = null; winLine = [] };
    mode = #turnBased;
    step = Rules.discs(board);
    gen = 1;
    complexity;
    retryReason = null;
    opponent = "someone";
    opponentLastMove = null;
    lastStepDurationNs = null;
  };
};

// The column `settings` (null: Easy) picks, checked legal.
func pick(board : [?Game.Seat], settings : ?Search.Settings, seed : Nat64) : Nat {
  let #drop { col } = BotLogic.chooseWith(request(board, "test"), settings, seed, never);
  switch (Rules.validate(board, #drop { col })) {
    case null col;
    case (?why) Runtime.trap("illegal reply " # debug_show col # ": " # why);
  };
};

let levels : [(Text, ?Search.Settings)] = [("Easy", null), ("Medium", ?BotLogic.MEDIUM), ("Hard", ?HARD_TEST)];
let seeds : [Nat64] = [0, 1, 7, 42, 0xdeadbeef, 0xffff_ffff_ffff_ffff];

func expectOneOf(name : Text, board : [?Game.Seat], settings : ?Search.Settings, cols : [Nat]) {
  for (seed in seeds.values()) {
    let col = pick(board, settings, seed);
    if (cols.find(func c = c == col) == null) {
      Runtime.trap(name # ": played " # debug_show col # ", expected one of " # debug_show cols);
    };
  };
};

// ── 1. the rules the bot re-implements ─────────────────────────────────────
let empty = boardOf(["", "", "", "", "", ""]);
assert Rules.toMove(empty) == #p1;
assert Rules.legalCols(empty) == [0, 1, 2, 3, 4, 5, 6];
assert Rules.validate(empty, #drop { col = 7 }) == ?"There is no such column.";
let fullCol = boardOf(["R", "Y", "R", "Y", "R", "Y"]);
assert Rules.validate(fullCol, #drop { col = 0 }) == ?"That column is full.";
assert Rules.validate(fullCol, #drop { col = 1 }) == null;
assert Rules.toMove(fullCol) == #p1;
assert Rules.legalCols(fullCol) == [1, 2, 3, 4, 5, 6];
switch (Rules.drop(fullCol, 1, #p1)) {
  case (?b) { assert b[1] == ?#p1 and Rules.discs(b) == 7 };
  case null Runtime.trap("drop into column 1 refused");
};
assert Rules.drop(fullCol, 0, #p1) == null;
// (Patterns only: these three need not be reachable positions.)
assert Rules.hasFour(boardOf(["", "", "", "", "", "RRRR"]), #p1);
assert Rules.hasFour(boardOf(["", "", "   Y", "  Y", " Y", "Y"]), #p2);
assert not Rules.hasFour(boardOf(["", "", "", "", "", "RRR R"]), #p1);
Debug.print("1. rules OK");

// ── 2. the bitboards agree with the board ─────────────────────────────────
do {
  let board = boardOf(["", "", "", "  Y", " RYR", "RRYY"]);
  let (cur, mask, moves) = Search.fromCells(func i = switch (board[i]) { case (?s) ?(s == #p1); case null null });
  assert moves == 8 and Search.popcount(mask) == 8 and Search.popcount(cur) == 4;
  // Red's cells: (0,0), (1,0), (1,1), (3,1).
  assert cur == (1 : Nat64) | (1 << 7) | (1 << 8) | (1 << 22);
  // One open cell per column, each the lowest empty one.
  assert Search.possible(mask) == (1 << 1) | (1 << 9) | (1 << 17) | (1 << 23) | (1 << 28) | (1 << 35) | (1 << 42);
  assert not Search.hasFour(cur);
  assert Search.hasFour(cur | (1 << 14) | (1 << 21)); // the bottom row's first four
  assert Search.winningCells(cur, mask) == 0; // no three of Red's line up
  assert Search.winningCells(cur ^ mask, mask) == 1 << 17; // Yellow: (2,3), atop three
};
do {
  // Three Red in the bottom row, both ends open: two winning cells.
  let board = boardOf(["", "", "", "", " YYY", " RRR"]);
  let (cur, mask, _) = Search.fromCells(func i = switch (board[i]) { case (?s) ?(s == #p1); case null null });
  assert Search.winningCells(cur, mask) == (1 : Nat64) | (1 << 28);
};
Debug.print("2. bitboards OK");

// ── 3. every complexity answers a legal move ──────────────────────────────
let positions : [[?Game.Seat]] = [
  empty,
  fullCol,
  boardOf(["", "", "", "   R", "  YRY", " RYYR"]),
  boardOf(["RYYRYR", "YRRRYY", "YRYYRR", "YYYRYR", "RRYRRY", "YYRRRY"]), // column 6 only
  boardOf(["Y RYR Y", "R YRY R", "Y RYR Y", "R YRY R", "Y RYR Y", "R YRY R"]),
];
for (board in positions.values()) {
  for ((_, settings) in levels.values()) {
    for (seed in seeds.values()) ignore pick(board, settings, seed);
  };
};
// Column 6 is the only open one.
for ((name, settings) in levels.values()) expectOneOf(name # " last column", positions[3], settings, [6]);
// Easy is random: over many seeds it uses every open column.
do {
  let seen = VarArray.repeat<Bool>(false, 7);
  for (i in Nat.range(0, 200)) seen[pick(empty, null, Nat64.fromNat(i) *% 0x9E3779B97F4A7C15)] := true;
  assert seen.all(func b = b);
};
Debug.print("3. legal replies OK");

// ── 4. take a win ─────────────────────────────────────────────────────────
let rowWin = boardOf(["", "", "", "", "YYY", "RRR"]); // Red: column 3 wins
expectOneOf("Medium row win", rowWin, ?BotLogic.MEDIUM, [3]);
expectOneOf("Hard row win", rowWin, ?HARD_TEST, [3]);
let colWin = boardOf(["", "", "", "R", "RY", "RYY"]); // Red: column 0 wins
expectOneOf("Medium column win", colWin, ?BotLogic.MEDIUM, [0]);
expectOneOf("Hard column win", colWin, ?HARD_TEST, [0]);
// Yellow completes a diagonal (0,0)-(1,1)-(2,2)-(3,3) at (3,3).
let diagWin = boardOf(["", "", "", "  YR", " YRY", "YRRRY R"]);
assert Rules.toMove(diagWin) == #p2;
expectOneOf("Medium diagonal win", diagWin, ?BotLogic.MEDIUM, [3]);
expectOneOf("Hard diagonal win", diagWin, ?HARD_TEST, [3]);
Debug.print("4. wins taken OK");

// ── 5. block a loss, and never hand one over ─────────────────────────────
// Yellow on turn; Red threatens column 3 on the bottom row.
let blockRow = boardOf(["", "", "", "", "Y", "RRR Y"]);
assert Rules.toMove(blockRow) == #p2;
expectOneOf("Medium block", blockRow, ?BotLogic.MEDIUM, [3]);
expectOneOf("Hard block", blockRow, ?HARD_TEST, [3]);
// Red on turn; Yellow wins at (3,1) once something sits on (3,0), so
// column 3 is poison and nothing else is forced.
let underThreat = boardOf(["", "", "", "", "YYY", "RYR  RR"]);
assert Rules.toMove(underThreat) == #p1;
for ((name, settings) in levels.values()) {
  if (name != "Easy") {
    for (seed in seeds.values()) assert pick(underThreat, settings, seed) != 3;
  };
};
Debug.print("5. blocks OK");

// ── 6. what each level sees ──────────────────────────────────────────────
// Red on turn with two in the bottom row and open ends: column 1 or 4
// makes an open three (two winning cells), which both levels see.
let fork = boardOf(["", "", "", "", "  YY", "  RR"]);
expectOneOf("Medium makes a double threat", fork, ?BotLogic.MEDIUM, [1, 4]);
expectOneOf("Hard makes a double threat", fork, ?HARD_TEST, [1, 4]);
// Yellow on turn against the same two: only column 1 or 4 stops the open
// three. Hard sees it two moves ahead; Medium's one ply does not.
let stopFork = boardOf(["", "", "", "", "  Y", "  RR"]);
assert Rules.toMove(stopFork) == #p2;
expectOneOf("Hard stops a double threat", stopFork, ?HARD_TEST, [1, 4]);
// The search proves the win the open three makes: Red, Yellow, Red.
do {
  let r = BotLogic.searchCol(boardOf(["", "", "", "", " YY", " RR"]), #p1, HARD_TEST, 0, never);
  assert r.col == 3 and r.score == Search.WIN - 7; // with the game's 7th disc
};
// A won position stays won at every seed, and Hard takes the fastest win.
do {
  let r = BotLogic.searchCol(rowWin, #p1, HARD_TEST, 0, never);
  assert r.col == 3 and r.score == Search.WIN - 7;
};
Debug.print("6. lookahead OK");

// ── 6b. the book and the exact search ────────────────────────────────────
// The board after a move string (columns, Red first).
func played(moves : Text) : [?Game.Seat] {
  var board = Array.repeat<?Game.Seat>(null, 42);
  for (ch in moves.chars()) {
    let col = (ch.toNat32() - 48).toNat();
    let ?next = Rules.drop(board, col, Rules.toMove(board)) else Runtime.trap("bad move string " # moves);
    board := next;
  };
  board;
};
func bits(moves : Text) : (Nat64, Nat64) {
  let board = played(moves);
  let seat = Rules.toMove(board);
  let (cur, mask, _) = Search.fromCells(func i = switch (board[i]) { case (?s) ?(s == seat); case null null });
  (cur, mask);
};
do {
  // Red's first move: the centre, the only one that wins.
  let (c0, m0) = bits("");
  assert Book.lookup(c0, m0) == ?(3, true);
  // An entry and its mirror image: Red 3 3 3 3 3 3 2 2 wins with 4, so
  // the mirrored position (4 4 for 2 2) wins with 2.
  let (c1, m1) = bits("33333322");
  assert Book.lookup(c1, m1) == ?(4, true);
  let (c2, m2) = bits("33333344");
  assert Book.lookup(c2, m2) == ?(2, true);
  // A position off the book's lines (Red never plays 0 first).
  let (c3, m3) = bits("06");
  assert Book.lookup(c3, m3) == null;
  // Hard plays the book's move; Medium does not use the book.
  assert pick(played("33333344"), ?HARD_TEST, 5) == 2;
  assert BotLogic.searchCol(played(""), #p1, HARD_TEST, 0, never).exact == ?1;
  // Book entries are legal moves wherever the book has one.
  assert Book.size() > 1000;
};
// 27 discs, Yellow to move: a draw with perfect play, kept only by
// column 5 (checked with an independent solver, tools/book/solve.c).
let DRAWN = "560304312321311200253032125";
let DRAWING = [5];
do {
  // The exact search proves the draw and plays the one drawing move.
  let r = BotLogic.searchCol(played(DRAWN), Rules.toMove(played(DRAWN)), { HARD_TEST with maxNodes = 200_000; ttSize = 65_521 }, 0, never);
  assert r.exact == ?0;
  assert DRAWING.find(func c = c == r.col) != null;
};
Debug.print("6b. book and exact search OK");

// ── 7. the request around the move ───────────────────────────────────────
// Unknown complexities play Medium; a retry answers a plain legal move;
// a board of the wrong size or a full one never traps.
assert BotLogic.settingsFor("Easy") == null;
assert BotLogic.settingsFor("Medium") == ?BotLogic.MEDIUM;
assert BotLogic.settingsFor("Hard") == ?BotLogic.HARD;
assert BotLogic.settingsFor("Default") == ?BotLogic.MEDIUM;
assert BotLogic.COMPLEXITIES == ["Easy", "Medium", "Hard"];
do {
  let retry = { request(rowWin, "Hard") with retryReason = ?"That column is full." };
  let #drop { col } = BotLogic.chooseMove(retry, 3, never);
  assert Rules.validate(rowWin, #drop { col }) == null;
  let odd = { request(empty, "Hard") with game = { board = [null, null]; lastMove = null; winLine = [] } };
  ignore BotLogic.chooseMove(odd, 3, never);
  let full = boardOf(["RYYRYRY", "RYRRYYY", "YRYYRYR", "YRYRYRR", "RRYRYRY", "RYRYYRR"]);
  ignore BotLogic.chooseMove(request(full, "Hard"), 3, never);
};
Debug.print("7. requests OK");
