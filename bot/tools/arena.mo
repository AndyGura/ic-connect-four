// Strength check, outside the canister: whole games between ways of
// playing, at full depth, compiled to WASI and run by tools/arena.mjs.
// Not part of `mops test` (it takes minutes). Hard is budgeted in nodes
// here; on the IC its budget is instructions (Bot.mo).
import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import Int "mo:core/Int";
import VarArray "mo:core/VarArray";
import Array "mo:core/Array";
import Prim "mo:⛔";
import Runtime "mo:core/Runtime";
import Text "mo:core/Text";
import Char "mo:core/Char";
import Nat32 "mo:core/Nat32";
import Int64 "mo:core/Int64";

import BotLogic "../src/BotLogic";
import Game "../src/GameTypes";
import Rules "../src/GameRules";
import Search "../src/Search";

let never = func() : Nat = 0;

type Player = { name : Text; settings : ?Search.Settings };

func hard(nodes : Nat) : Player = {
  name = "Hard@" # nodes.toText();
  settings = ?{ BotLogic.HARD with maxNodes = nodes };
};
// A careful, non-random player: a fixed-depth search (no book, no exact
// search) that always plays what it thinks best. Stands in for a person
// who thinks a few moves ahead.
func careful(depth : Nat) : Player = {
  name = "Careful" # depth.toText();
  settings = ?{ BotLogic.HARD with maxDepth = depth; maxNodes = 10_000_000; ttSize = 65_521; book = false; solveFrom = 43 };
};
// `careful`, plus an exact search from the 12th disc on with eight
// million nodes (far more than Hard's budget): near-perfect endgames.
func solver(depth : Nat) : Player = {
  name = "Solver" # depth.toText();
  settings = ?{ BotLogic.HARD with maxDepth = depth; maxNodes = 10_000_000; ttSize = 1_048_573; book = false };
};
// Hard with another table size and exact-search share, for tuning.
func hardWith(nodes : Nat, tt : Nat, share : Nat, from : Nat) : Player = {
  name = "Hard@" # nodes.toText() # "/tt" # tt.toText() # "/share" # share.toText() # "/from" # from.toText();
  settings = ?{ BotLogic.HARD with maxNodes = nodes; ttSize = tt; solveShare = share; solveFrom = from };
};
let EASY : Player = { name = "Easy"; settings = null };
let MEDIUM : Player = { name = "Medium"; settings = ?BotLogic.MEDIUM };

var hardMoves = 0;
var hardDepth = 0;
var hardNodes = 0;
var hardMaxNodes = 0;

func request(board : [?Game.Seat]) : {
  tableId : Nat;
  seat : Game.Seat;
  game : Game.View;
  mode : { #simultaneous; #turnBased };
  step : Nat;
  gen : Nat;
  complexity : Text;
  retryReason : ?Text;
  opponent : Text;
  opponentLastMove : ?Game.Action;
  lastStepDurationNs : ?Int;
} = {
  tableId = 0;
  seat = Rules.toMove(board);
  game = { board; lastMove = null; winLine = [] };
  mode = #turnBased;
  step = Rules.discs(board);
  gen = 0;
  complexity = "";
  retryReason = null;
  opponent = "";
  opponentLastMove = null;
  lastStepDurationNs = null;
};

func moveOf(p : Player, board : [?Game.Seat], seed : Nat64) : Nat {
  switch (p.settings) {
    case null {
      let #drop { col } = BotLogic.chooseWith(request(board), null, seed, never);
      col;
    };
    case (?s) {
      let r = BotLogic.searchCol(board, Rules.toMove(board), s, BotLogic.mix(seed, request(board)), never);
      if (p.name.startsWith(#text "Hard")) {
        hardMoves += 1;
        hardDepth += r.depth;
        hardNodes += r.nodes;
        if (r.nodes > hardMaxNodes) hardMaxNodes := r.nodes;
      };
      r.col;
    };
  };
};

// Answers 1 when Red wins, 2 when Yellow wins, 0 for a draw.
func play(red : Player, yellow : Player, seed : Nat64, opening : [Nat]) : (Nat, Text) {
  var board : [?Game.Seat] = Array.repeat<?Game.Seat>(null, 42);
  var moves = "";
  var ply = 0;
  loop {
    let seat = Rules.toMove(board);
    let col = if (ply < opening.size()) opening[ply] else moveOf(if (seat == #p1) red else yellow, board, seed *% 0x9E3779B97F4A7C15 +% Nat.toNat64(ply));
    let ?next = Rules.drop(board, col, seat) else Runtime.trap("illegal move " # col.toText() # " after " # moves);
    board := next;
    moves #= col.toText();
    ply += 1;
    if (Rules.hasFour(board, seat)) return (if (seat == #p1) 1 else 2, moves);
    if (ply == 42) return (0, moves);
  };
};

// Both colours, `pairs` games each, from the two-ply openings in turn, in
// this one instance: Motoko collects no garbage in a WASI program, so for
// Hard (fresh tables every move) use tools/match.py instead.
func match_(a : Player, b : Player, pairs : Nat) {
  var aw = 0;
  var bw = 0;
  var draws = 0;
  hardMoves := 0;
  hardDepth := 0;
  hardNodes := 0;
  hardMaxNodes := 0;
  var log = "";
  for (i in Nat.range(0, pairs)) {
    let opening = if (i == 0) [] else [i % 7, (i / 7) % 7];
    for (aRed in [true, false].values()) {
      let seed = Nat.toNat64(i * 2 + (if aRed 0 else 1) + 1);
      let (res, moves) = if (aRed) play(a, b, seed, opening) else play(b, a, seed, opening);
      let aWon = (aRed and res == 1) or (not aRed and res == 2);
      let bWon = (aRed and res == 2) or (not aRed and res == 1);
      if (aWon) aw += 1 else if (bWon) bw += 1 else draws += 1;
      if (bWon) log #= " " # (if aRed "R:" else "Y:") # moves;
    };
  };
  let depthAvg = if (hardMoves == 0) 0 else hardDepth * 10 / hardMoves;
  let nodesAvg = if (hardMoves == 0) 0 else hardNodes / hardMoves;
  Debug.print(
    a.name # " vs " # b.name # ": " # aw.toText() # " won, " # draws.toText() # " drawn, " # bw.toText() # " lost" #
    (if (hardMoves > 0) " | Hard depth avg " # (depthAvg / 10).toText() # "." # (depthAvg % 10).toText() # ", nodes avg " # nodesAvg.toText() # " max " # hardMaxNodes.toText() else "") #
    (if (log != "") " | lost:" # log else "")
  );
};


// Prints the move string of `count` games between `a` (Red) and `b`, each
// from a random two-ply opening, for building test positions.
func games(a : Player, b : Player, count : Nat, salt : Nat) {
  for (i in Nat.range(0, count)) {
    let seed = Nat.toNat64(i * 7919 + salt);
    let r = BotLogic.mix(seed, request(Array.repeat<?Game.Seat>(null, 42)));
    let opening = [(r % 7).toNat(), ((r >> 8) % 7).toNat()];
    let (_, moves) = play(a, b, seed, opening);
    Debug.print("GAME " # moves);
  };
};

// Prints what `p` plays in each position (a move string), with the
// search's depth and nodes: "PROBE <moves> <col> <depth> <nodes> <exact>".
func probe(p : Player, positions : [Text]) {
  for (moves in positions.values()) {
    var board : [?Game.Seat] = Array.repeat<?Game.Seat>(null, 42);
    var ply = 0;
    for (ch in moves.chars()) {
      let c = Nat32.toNat(Char.toNat32(ch) - 48);
      let ?next = Rules.drop(board, c, if (ply % 2 == 0) #p1 else #p2) else Runtime.trap("bad position " # moves);
      board := next;
      ply += 1;
    };
    let s = switch (p.settings) { case (?s) s; case null BotLogic.MEDIUM };
    let r = BotLogic.searchCol(board, Rules.toMove(board), s, Nat.toNat64(ply), never);
    Debug.print("PROBE " # moves # " " # r.col.toText() # " " # r.depth.toText() # " " # r.nodes.toText() # " " # debug_show r.exact);
  };
};


// One game of a match (pair `i`, `a` as Red or Yellow), as a line
// "GAMERESULT <a won: 1, lost: -1, draw: 0> <colour> <moves>" for
// tools/match.py, which runs each game in its own instance.
func game_(a : Player, b : Player, i : Nat, aRed : Bool) {
  let opening = if (i == 0) [] else [i % 7, (i / 7) % 7];
  let seed = Nat.toNat64(i * 2 + (if aRed 0 else 1) + 1);
  let (res, moves) = if (aRed) play(a, b, seed, opening) else play(b, a, seed, opening);
  let aWon = (aRed and res == 1) or (not aRed and res == 2);
  let bWon = (aRed and res == 2) or (not aRed and res == 1);
  Debug.print("GAMERESULT " # (if aWon "1" else if bWon "-1" else "0") # " " # (if aRed "R" else "Y") # " " # moves);
};

// Like `game_`, but only `b`'s first two moves are forced (to i % 7 and
// (i / 7) % 7): `a` plays every move of its own, as it would live.
func free_(a : Player, b : Player, i : Nat, aRed : Bool) {
  let forced = [i % 7, (i / 7) % 7];
  var board : [?Game.Seat] = Array.repeat<?Game.Seat>(null, 42);
  var moves = "";
  var ply = 0;
  var bMoves = 0;
  let seed = Nat.toNat64(i * 2 + (if aRed 0 else 1) + 1);
  var res : Int = 0;
  label game loop {
    let seat = Rules.toMove(board);
    let aTurn = (seat == #p1) == aRed;
    let col = if (not aTurn and bMoves < 2) forced[bMoves] else moveOf(if aTurn a else b, board, seed *% 0x9E3779B97F4A7C15 +% Nat.toNat64(ply));
    if (not aTurn) bMoves += 1;
    let ?next = Rules.drop(board, col, seat) else {
      // A forced move into a full column: take the leftmost open one.
      let ?n2 = Rules.drop(board, Rules.legalCols(board)[0], seat) else Runtime.trap("no move");
      board := n2;
      moves #= Rules.legalCols(board)[0].toText();
      ply += 1;
      continue game;
    };
    board := next;
    moves #= col.toText();
    ply += 1;
    if (Rules.hasFour(board, seat)) { res := if (aTurn) 1 else -1; break game };
    if (ply == 42) break game;
  };
  Debug.print("GAMERESULT " # (if (res == 1) "1" else if (res == -1) "-1" else "0") # " " # (if aRed "R" else "Y") # " " # moves);
};

// __MATCHES__
