import Array "mo:core/Array";
import Int "mo:core/Int";
import Nat "mo:core/Nat";

import Game "GameTypes";

/// The parts of the semantics' RULES and ENDINGS the bot needs, over the
/// `View`'s own board. The live game stays the judge; these only keep the
/// bot from proposing a move it would reject.
module {

  public let COLS = 7;
  public let ROWS = 6;
  public let CELLS = 42;

  public func index(col : Nat, row : Nat) : Nat = row * COLS + col;

  public func discs(board : [?Game.Seat]) : Nat {
    var n = 0;
    for (c in board.values()) { if (c != null) n += 1 };
    n;
  };

  /// "Red is on turn when the board holds an even number of discs."
  public func toMove(board : [?Game.Seat]) : Game.Seat {
    if (discs(board) % 2 == 0) #p1 else #p2;
  };

  /// "A column is playable while its top cell (index 35 + col) is empty."
  public func playable(board : [?Game.Seat], col : Nat) : Bool {
    col < COLS and board.size() == CELLS and board[35 + col] == null;
  };

  public func legalCols(board : [?Game.Seat]) : [Nat] {
    [0, 1, 2, 3, 4, 5, 6].filter(func c = playable(board, c));
  };

  /// `null` when the game would accept `action`, else its rejection text.
  public func validate(board : [?Game.Seat], action : Game.Action) : ?Text {
    let #drop { col } = action;
    if (col >= COLS) return ?"There is no such column.";
    if (not playable(board, col)) return ?"That column is full.";
    null;
  };

  /// The row a disc dropped into `col` lands on (the lowest empty cell).
  public func landingRow(board : [?Game.Seat], col : Nat) : ?Nat {
    var row = 0;
    while (row < ROWS) {
      if (board[index(col, row)] == null) return ?row;
      row += 1;
    };
    null;
  };

  /// The board after `seat` drops into `col`; `null` when that is illegal.
  public func drop(board : [?Game.Seat], col : Nat, seat : Game.Seat) : ?[?Game.Seat] {
    if (validate(board, #drop { col }) != null) return null;
    let ?row = landingRow(board, col) else return null;
    let at = index(col, row);
    ?Array.tabulate<?Game.Seat>(CELLS, func i = if (i == at) ?seat else board[i]);
  };

  /// Whether `seat` has four or more in a row, column or diagonal.
  public func hasFour(board : [?Game.Seat], seat : Game.Seat) : Bool {
    let dirs : [(Int, Int)] = [(1, 0), (0, 1), (1, 1), (1, -1)];
    for (row in Nat.range(0, ROWS)) {
      for (col in Nat.range(0, COLS)) {
        for ((dc, dr) in dirs.values()) {
          var k = 0;
          label run while (k < 4) {
            let c : Int = col + dc * k;
            let r : Int = row + dr * k;
            if (c < 0 or c >= COLS or r < 0 or r >= ROWS) break run;
            if (board[Int.abs(r) * COLS + Int.abs(c)] != ?seat) break run;
            k += 1;
          };
          if (k == 4) return true;
        };
      };
    };
    false;
  };

};
