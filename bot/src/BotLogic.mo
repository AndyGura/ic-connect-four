import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";

import TP "mo:duel-game-core";

import Game "GameTypes";
import Rules "GameRules";
import Search "Search";

/// `chooseMove` for every complexity. No actor, no `Time`, no storage:
/// `Bot.mo` passes the time as `seed` and its instruction budget as
/// `outOfTime`.
module {

  public let COMPLEXITIES : [Text] = ["Easy", "Medium", "Hard"];
  public let DEFAULT = "Medium";

  /// Medium sees one move ahead: it takes a win, blocks one, never hands
  /// one over and spots a double threat it can make right now, but not
  /// one the opponent is building. Among moves of about equal value it
  /// picks at random.
  public let MEDIUM : Search.Settings = {
    maxDepth = 1;
    margin = 10;
    extendForced = false;
    maxNodes = 10_000;
    ttSize = 1;
  };

  /// Hard deepens until its budget runs out (or the game is solved from
  /// here) and plays the best move it found; equal moves at random.
  public let HARD : Search.Settings = {
    maxDepth = 42;
    margin = 0;
    extendForced = true;
    maxNodes = 5_000_000;
    ttSize = 131_071;
  };

  /// `null` for Easy: a random legal move.
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
  public func chooseMove(req : TP.MoveRequest<Game.View, Game.Action>, seed : Nat64, outOfTime : () -> Bool) : Game.Action {
    chooseWith(req, settingsFor(req.complexity), seed, outOfTime);
  };

  /// `chooseMove` with explicit settings (`null`: random), for tests.
  public func chooseWith(req : TP.MoveRequest<Game.View, Game.Action>, settings : ?Search.Settings, seed : Nat64, outOfTime : () -> Bool) : Game.Action {
    let board = req.game.board;
    let legal = Rules.legalCols(board);
    if (legal.size() == 0) return #drop { col = 0 }; // the game is over; never trap
    let rnd = mix(seed, req);
    let random = #drop { col = legal[Nat64.toNat(rnd % Nat.toNat64(legal.size()))] };
    // A rejected reply is asked once more: answer with a plain legal move.
    if (req.retryReason != null) return random;
    let ?s = settings else return random;
    let col = searchCol(board, req.seat, s, rnd, outOfTime).col;
    let move = #drop { col };
    if (Rules.validate(board, move) == null) move else random;
  };

  /// The search's full answer, for tests and for the depth it reached.
  public func searchCol(board : [?Game.Seat], seat : Game.Seat, settings : Search.Settings, seed : Nat64, outOfTime : () -> Bool) : Search.Result {
    let (cur, mask, moves) = Search.fromCells(
      func i = switch (board[i]) {
        case (?s) ?(s == seat);
        case null null;
      }
    );
    Search.Searcher(settings, outOfTime).best(cur, mask, moves, seed);
  };

};
