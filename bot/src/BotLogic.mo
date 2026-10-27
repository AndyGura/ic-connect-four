import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";

import TP "mo:duel-game-core";

import Game "GameTypes";
import Rules "GameRules";
import Search "Search";

/// `chooseMove` for every complexity. No actor, no `Time`, no storage:
/// `Bot.mo` passes the time as `seed` and its instruction counter as
/// `clock`.
module {

  public let COMPLEXITIES : [Text] = ["Easy", "Medium", "Hard"];

  /// Medium sees one move ahead: it takes a win, blocks one, never hands
  /// one over and spots a double threat it can make right now, but not
  /// one the opponent is building. Among moves of about equal value it
  /// picks at random.
  public let MEDIUM : Search.Settings = {
    maxDepth = 1;
    margin = 10;
    extendForced = false;
    maxNodes = 10_000;
    maxWork = 0;
    solveFrom = 43;
    solveShare = 0;
    ttSize = 1;
    rules = false;
    book = false;
  };

  /// Hard plays the opening book's move where it has one (`Book.mo`);
  /// from the 12th disc on it first tries to solve the position outright
  /// (within 80% of its budget), then deepens its heuristic search until
  /// the budget runs out: 1.2 billion instructions per move, well inside
  /// a query's limit (about 0.0005 TC per move). Equal moves at random.
  public let HARD : Search.Settings = {
    maxDepth = 42;
    margin = 0;
    extendForced = true;
    maxNodes = 10_000_000;
    maxWork = 1_200_000_000;
    solveFrom = 12;
    solveShare = 80;
    ttSize = 1_048_573;
    rules = true;
    book = true;
  };

  /// `null` for Easy: a random legal move. Anything unknown plays Medium.
  public func settingsFor(complexity : Text) : ?Search.Settings {
    switch (complexity) {
      case "Easy" null;
      case "Hard" ?HARD;
      case _ ?MEDIUM;
    };
  };

  /// A 64-bit mix of the seed with the seat and the step, so two copies
  /// of the bot asked in the same instant still differ.
  public func mix(seed : Nat64, req : TP.MoveRequest<Game.View, Game.Action>) : Nat64 {
    var z = seed +% Nat.toNat64(req.step % 64) *% 0x9E3779B97F4A7C15 +% (if (req.seat == #p1) 1 else 2);
    z := (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z := (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    z ^ (z >> 31);
  };

  /// The bot's move, at its complexity.
  public func chooseMove(req : TP.MoveRequest<Game.View, Game.Action>, seed : Nat64, clock : () -> Nat) : Game.Action {
    chooseWith(req, settingsFor(req.complexity), seed, clock);
  };

  /// `chooseMove` with explicit settings (`null`: random), for tests.
  public func chooseWith(req : TP.MoveRequest<Game.View, Game.Action>, settings : ?Search.Settings, seed : Nat64, clock : () -> Nat) : Game.Action {
    let board = req.game.board;
    let legal = Rules.legalCols(board);
    if (legal.size() == 0) return #drop { col = 0 }; // the game is over; never trap
    let rnd = mix(seed, req);
    let random = #drop { col = legal[Nat64.toNat(rnd % legal.size().toNat64())] };
    // A rejected reply is asked once more: answer with a plain legal move.
    if (req.retryReason != null) return random;
    let ?s = settings else return random;
    let col = searchCol(board, req.seat, s, rnd, clock).col;
    let move = #drop { col };
    if (Rules.validate(board, move) == null) move else random;
  };

  /// The search's full answer, for tests and for the depth it reached.
  public func searchCol(board : [?Game.Seat], seat : Game.Seat, settings : Search.Settings, seed : Nat64, clock : () -> Nat) : Search.Result {
    let (cur, mask, moves) = Search.fromCells(
      func i = switch (board[i]) {
        case (?s) ?(s == seat);
        case null null;
      }
    );
    Search.Searcher(settings, clock).best(cur, mask, moves, seed);
  };

};
