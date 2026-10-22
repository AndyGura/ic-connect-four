// Unit checks for ConnectFourRules: init/validate/resolve/move called
// directly against synthetic boards, no engine. One block per illegal
// move and per win/draw path. `assert` + `Runtime.trap`.
//
// Run: mops test
import R "../src/ConnectFourRules";
import TP "mo:duel-game-core";
import Rng "mo:duel-game-core/rng";
import Array "mo:core/Array";
import Debug "mo:core/Debug";
import Runtime "mo:core/Runtime";
import VarArray "mo:core/VarArray";

// A fixed seed makes every run identical.
let rng = Rng.new(42);
let options : R.Options = {};

// A board drawn as it stands: six rows, TOP row first, 'R' = Red (#p1),
// 'Y' = Yellow (#p2), anything else empty.
func boardOf(rows : [Text]) : R.Board {
  assert rows.size() == 6;
  let cells = VarArray.repeat<?TP.Seat>(null, 42);
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

func stateOf(rows : [Text]) : R.State = {
  board = boardOf(rows);
  lastMove = null;
  winLine = [];
};

// One action, trapping on a rejection or an unexpected end.
func step(s : R.State, seat : TP.Seat, a : R.Action) : R.State {
  switch (R.move(s, seat, a, rng)) {
    case (#err why) Runtime.trap("rejected: " # why);
    case (#ok { verdict = ?_ }) Runtime.trap("unexpected end");
    case (#ok { state; verdict = null }) state;
  };
};

// One action that must end the game with `expected`; returns the state.
func finish(s : R.State, seat : TP.Seat, col : Nat, expected : TP.Verdict) : R.State {
  switch (R.move(s, seat, #drop { col }, rng)) {
    case (#err why) Runtime.trap("rejected: " # why);
    case (#ok { state; verdict = ?v }) {
      if (v != expected) Runtime.trap("wrong verdict");
      state;
    };
    case (#ok { verdict = null }) Runtime.trap("expected the game to end");
  };
};

// ── 1. checkOptions, init, spec wiring ─────────────────────────────────────
assert R.checkOptions(options) == null;
let s0 = R.init(options, rng);
assert s0.board.size() == 42;
assert s0.board.all(func(c : ?TP.Seat) : Bool = c == null);
assert s0.lastMove == null;
assert s0.winLine.size() == 0;
assert R.toMove(s0) == #p1;
let sp = switch (R.spec) {
  case (#turnBased s) s;
  case (#simultaneous _) Runtime.trap("Connect Four is a #turnBased game");
};
assert sp.init(options, rng) == s0;
assert sp.toMove(s0) == #p1;
Debug.print("1. options + init + spec wiring OK");

// ── 2. validate: every column of an empty board, nothing off the board,
//      nothing into a full column ───────────────────────────────────────────
for (col in [0, 1, 2, 3, 4, 5, 6].values()) {
  switch (R.validate(s0, #p1, #drop { col })) {
    case null {};
    case (?why) Runtime.trap("an empty column must be legal: " # why);
  };
};
switch (R.validate(s0, #p1, #drop { col = 7 })) {
  case (?"There is no such column.") {};
  case (_) Runtime.trap("column 7 must be off the board");
};
let fullMiddle = stateOf([
  "...Y...",
  "...R...",
  "...Y...",
  "...R...",
  "...Y...",
  "...R...",
]);
switch (R.validate(fullMiddle, #p1, #drop { col = 3 })) {
  case (?"That column is full.") {};
  case (_) Runtime.trap("a column of six discs must be full");
};
switch (R.move(fullMiddle, #p1, #drop { col = 3 }, rng)) {
  case (#err _) {};
  case (#ok _) Runtime.trap("move must refuse a full column");
};
switch (R.move(s0, #p1, #drop { col = 9 }, rng)) {
  case (#err _) {};
  case (#ok _) Runtime.trap("move must refuse a column off the board");
};
Debug.print("2. validate OK");

// ── 3. legalActions mirrors validate ───────────────────────────────────────
assert R.legalActions(s0, #p1).size() == 7;
do {
  let moves = R.legalActions(fullMiddle, #p1);
  assert moves.size() == 6;
  for (a in moves.values()) {
    switch (a) { case (#drop { col }) assert col != 3 };
    switch (R.validate(fullMiddle, #p1, a)) {
      case null {};
      case (?why) Runtime.trap("legalActions produced an illegal drop: " # why);
    };
  };
};
Debug.print("3. legalActions OK");

// ── 4. a disc falls to the lowest empty cell; turns alternate ──────────────
let s1 = step(s0, #p1, #drop { col = 3 });
assert s1.board[3] == ?#p1;
assert s1.lastMove == ?{ col = 3; row = 0; seat = #p1 };
assert R.toMove(s1) == #p2;
let s2 = step(s1, #p2, #drop { col = 3 });
assert s2.board[10] == ?#p2; // row 1, col 3
assert s2.lastMove == ?{ col = 3; row = 1; seat = #p2 };
assert R.toMove(s2) == #p1;
let s3 = step(s2, #p1, #drop { col = 0 });
assert s3.board[0] == ?#p1;
assert s3.board[3] == ?#p1 and s3.board[10] == ?#p2;
assert R.toMove(s3) == #p2;
assert s3.winLine.size() == 0;
Debug.print("4. drops + turn order OK");

// ── 5. horizontal four ─────────────────────────────────────────────────────
do {
  let s = stateOf([
    ".......",
    ".......",
    ".......",
    ".......",
    "YYY....",
    "RRR....",
  ]);
  let f = finish(s, #p1, 3, #p1Wins);
  assert f.winLine == [0, 1, 2, 3];
  assert f.lastMove == ?{ col = 3; row = 0; seat = #p1 };
};
Debug.print("5. horizontal win OK");

// ── 6. vertical four ───────────────────────────────────────────────────────
do {
  let s = stateOf([
    ".......",
    ".......",
    ".......",
    "......Y",
    "R.....Y",
    "RR....Y",
  ]);
  let f = finish(s, #p2, 6, #p2Wins);
  assert f.winLine == [6, 13, 20, 27];
};
Debug.print("6. vertical win OK");

// ── 7. rising diagonal, completed at its top end ───────────────────────────
do {
  let s = stateOf([
    ".......",
    ".......",
    ".......",
    "..RY...",
    ".RYR...",
    "RYYY...",
  ]);
  let f = finish(s, #p1, 3, #p1Wins);
  assert f.winLine == [0, 8, 16, 24];
};
Debug.print("7. rising diagonal win OK");

// ── 8. falling diagonal, completed in its middle ───────────────────────────
do {
  let s = stateOf([
    ".......",
    ".......",
    "Y......",
    "RY.....",
    "YR.....",
    "RRRY...",
  ]);
  let f = finish(s, #p2, 2, #p2Wins);
  assert f.winLine == [3, 9, 15, 21];
};
Debug.print("8. falling diagonal win OK");

// ── 9. five in a row lists all five; two lines at once list both ───────────
do {
  let five = stateOf([
    ".......",
    ".......",
    ".......",
    ".......",
    "YY.YY..",
    "RR.RR..",
  ]);
  assert finish(five, #p1, 2, #p1Wins).winLine == [0, 1, 2, 3, 4];

  let cross = stateOf([
    ".......",
    ".......",
    "RRR....",
    "YYYR...",
    "YYYR...",
    "YYYR...",
  ]);
  assert finish(cross, #p1, 3, #p1Wins).winLine == [3, 10, 17, 21, 22, 23, 24];
};
Debug.print("9. long and double lines OK");

// ── 10. three, or a line broken by the other colour, is not a win ──────────
do {
  let three = stateOf([
    ".......",
    ".......",
    ".......",
    ".......",
    ".......",
    "RR.....",
  ]);
  let t = step(three, #p1, #drop { col = 2 });
  assert t.winLine.size() == 0;

  let broken = stateOf([
    ".......",
    ".......",
    ".......",
    ".......",
    "YY.Y...",
    "RRYR...",
  ]);
  let b = step(broken, #p1, #drop { col = 4 });
  assert b.board[4] == ?#p1;
  assert b.winLine.size() == 0;

  // Four of Yellow does not win for Red, who just dropped elsewhere.
  let other = stateOf([
    ".......",
    ".......",
    ".......",
    ".......",
    ".......",
    "YYY....",
  ]);
  assert step(other, #p1, #drop { col = 3 }).winLine.size() == 0;
};
Debug.print("10. no false wins OK");

// ── 11. the 42nd disc without a line is a draw ─────────────────────────────
do {
  let s = stateOf([
    "RYYRRY.",
    "YYRRYYR",
    "RRYYRRY",
    "YYRRYYR",
    "RRYYRRY",
    "RRYYRRY",
  ]);
  assert R.toMove(s) == #p2; // 41 discs
  let f = finish(s, #p2, 6, #draw);
  assert f.board.all(func(c : ?TP.Seat) : Bool = c != null);
  assert f.winLine.size() == 0;
  assert R.legalActions(f, #p1).size() == 0;
};
Debug.print("11. draw on a full board OK");

// ── 12. a line on the 42nd disc is a win, not a draw ───────────────────────
do {
  let s = stateOf([
    "RRRYYY.",
    "YYRRYYR",
    "RRYYRRY",
    "YYRRYYR",
    "RRYYRRY",
    "RRYYRRY",
  ]);
  let f = finish(s, #p2, 6, #p2Wins);
  assert f.winLine == [38, 39, 40, 41];
};
Debug.print("12. last-cell win beats the draw OK");

// ── 13. nothing is hidden ──────────────────────────────────────────────────
assert R.view(s3, #p1, false) == s3;
assert R.view(s3, #p2, true) == s3;
Debug.print("13. view OK");

Debug.print("ALL ConnectFourRules RULESUNIT CHECKS PASSED");
