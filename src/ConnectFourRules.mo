/// ConnectFourRules — Connect Four game logic, as a pure `#turnBased`
/// module.
///
/// Seats: #p1 = Red (drops first), #p2 = Yellow (display only).
///
/// Rules:
///   BOARD  7 columns by 6 rows, standing upright, empty at the start.
///          Cells are row-major from the bottom: index = row * 7 + col,
///          row 0 the bottom row, col 0 the leftmost column.
///   DROP   the seat on turn drops one disc of its colour into any column
///          that is not full; it falls to that column's lowest empty cell.
///   TURNS  Red and Yellow alternate, Red first; one disc per turn, no
///          passing. Whose turn it is follows from the number of discs.
///   WIN    four or more discs of one colour in an unbroken line —
///          horizontal, vertical or diagonal — win at once for that colour.
///   DRAW   all 42 cells filled without a line of four.

import TP "mo:duel-game-core";
import Array "mo:core/Array";
import Int "mo:core/Int";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Runtime "mo:core/Runtime";

module {

  /// Served at `GET /semantics`: everything a frontend author who cannot
  /// see this file needs.
  public let SEMANTICS : Text = "GAME: Connect Four
MODE: turnBased (one action per turn, seats alternate)
SEATS: p1 = Red (drops first), p2 = Yellow
OPTIONS: none (type Options = record {})

VIEW (Candid)
  type Seat = variant { p1; p2 };
  type LastMove = record { col : nat; row : nat; seat : Seat };
  type View = record {
    board : vec opt Seat;
    lastMove : opt LastMove;
    winLine : vec nat;
  };
  board has 42 cells, 7 columns by 6 rows, row-major from the BOTTOM:
  index = row * 7 + col, row 0 is the bottom row, col 0 the leftmost
  column. null = empty, opt p1 = a Red disc, opt p2 = a Yellow disc.
  lastMove is the most recent drop (its column, the row it landed on and
  who dropped it); null before the first disc.
  winLine lists, in ascending order, the cell index of every disc that
  belongs to a completed line of four or more; empty while nobody has
  won. A single drop can complete several lines at once: all of their
  discs are listed.
  Nothing is hidden: both seats see the whole state.

ACTION (Candid)
  type Action = variant { drop : record { col : nat } };

RULES
  The seat on turn drops one disc into column col (0..6); it lands on the
  lowest empty cell of that column. Seats alternate, Red first: Red is on
  turn when the board holds an even number of discs.
  Rejected: col >= 7 (There is no such column.), or the column already
  holds six discs (That column is full.).

ENDINGS
  The drop that completes four or more discs of one colour in a row,
  column or diagonal wins for that colour: p1Wins for Red, p2Wins for
  Yellow.
  The 42nd disc without a line of four: draw.

CLIENT NOTES
  A column is playable while its top cell (index 35 + col) is empty.
  Highlight lastMove as the opponent's most recent drop while it is your
  turn, and winLine once the game is over (the debrief's final View).
";

  public let COLS : Nat = 7;
  public let ROWS : Nat = 6;
  let CELLS : Nat = 42;

  /// (row step, column step) of the four line directions: horizontal,
  /// vertical, and the two diagonals.
  let DIRECTIONS : [(Int, Int)] = [(0, 1), (1, 0), (1, 1), (1, -1)];

  public type Board = [?TP.Seat];

  /// The raw decision only: which column to drop into. The landing row is
  /// the rules' to compute.
  public type Action = { #drop : { col : Nat } };

  public type LastMove = { col : Nat; row : Nat; seat : TP.Seat };

  public type State = {
    board : Board;
    lastMove : ?LastMove;
    /// Every disc of a completed line, ascending; [] while nobody has won.
    winLine : [Nat];
  };

  /// Nothing is hidden: every seat sees the whole state.
  public type View = State;

  /// No table options: the classic 7x6 board, Red first.
  public type Options = {};

  public func checkOptions(_ : Options) : ?Text = null;

  public func sideName(seat : TP.Seat) : Text = switch (seat) {
    case (#p1) "Red";
    case (#p2) "Yellow";
  };

  public func init(_ : Options, _rng : TP.Rng) : State = {
    board = Array.repeat<?TP.Seat>(null, CELLS);
    lastMove = null;
    winLine = [];
  };

  func discCount(board : Board) : Nat = board.filter(func(c : ?TP.Seat) : Bool = c != null).size();

  /// Red is on turn after an even number of discs.
  public func toMove(s : State) : TP.Seat = if (discCount(s.board) % 2 == 0) #p1 else #p2;

  /// The row a disc dropped into `col` lands on; null when it is full.
  public func landingRow(board : Board, col : Nat) : ?Nat {
    for (row in Nat.range(0, ROWS)) {
      if (board[row * COLS + col] == null) return ?row;
    };
    null;
  };

  /// The cell at (row, col), null off the board as well as when empty.
  func cellAt(board : Board, row : Int, col : Int) : ?TP.Seat {
    if (row < 0 or col < 0 or row >= ROWS or col >= COLS) return null;
    board[Int.abs(row) * COLS + Int.abs(col)];
  };

  /// Every cell of each line of four or more through (row, col) in
  /// `seat`'s colour, ascending; [] when there is none.
  public func linesThrough(board : Board, row : Nat, col : Nat, seat : TP.Seat) : [Nat] {
    let out = List.empty<Nat>();
    for ((dr, dc) in DIRECTIONS.values()) {
      let line = List.singleton<Nat>(row * COLS + col);
      for (sign in [1, -1].values()) {
        var r : Int = row + sign * dr;
        var c : Int = col + sign * dc;
        while (cellAt(board, r, c) == ?seat) {
          line.add(Int.abs(r) * COLS + Int.abs(c));
          r += sign * dr;
          c += sign * dc;
        };
      };
      if (line.size() >= 4) {
        for (i in line.values()) {
          if (not out.contains(i)) out.add(i);
        };
      };
    };
    out.toArray().sort();
  };

  /// Every column with room — exactly what `validate` accepts.
  public func legalActions(s : State, _seat : TP.Seat) : [Action] {
    let out = List.empty<Action>();
    for (col in Nat.range(0, COLS)) {
      if (landingRow(s.board, col) != null) out.add(#drop { col });
    };
    out.toArray();
  };

  /// null = legal. The only legality gate in the system; the frontend's
  /// disabled columns are cosmetic. The engine has already rejected a
  /// seat that is not on turn.
  public func validate(s : State, _seat : TP.Seat, a : Action) : ?Text {
    switch (a) {
      case (#drop { col }) {
        if (col >= COLS) return ?"There is no such column.";
        switch (landingRow(s.board, col)) {
          case null ?"That column is full.";
          case (?_) null;
        };
      };
    };
  };

  /// Applies a drop `validate` accepted.
  public func resolve(s : State, seat : TP.Seat, a : Action) : {
    state : State;
    verdict : ?TP.Verdict;
  } {
    let col = switch (a) { case (#drop d) d.col };
    let row = switch (landingRow(s.board, col)) {
      case (?r) r;
      case null Runtime.trap("resolve: column " # col.toText() # " is full; validate first");
    };
    let at = row * COLS + col;
    let board = s.board.mapEntries<?TP.Seat, ?TP.Seat>(func(cur, j) = if (j == at) ?seat else cur);
    let winLine = linesThrough(board, row, col, seat);

    let verdict : ?TP.Verdict = if (winLine.size() > 0) {
      ?(switch (seat) { case (#p1) #p1Wins; case (#p2) #p2Wins });
    } else if (discCount(board) == CELLS) ?#draw else null;

    { state = { board; lastMove = ?{ col; row; seat }; winLine }; verdict };
  };

  /// One action of the seat on turn: checked, then applied.
  public func move(s : State, seat : TP.Seat, a : Action, _rng : TP.Rng) : {
    #ok : { state : State; verdict : ?TP.Verdict };
    #err : Text;
  } = switch (validate(s, seat, a)) {
    case (?why) #err why;
    case null #ok(resolve(s, seat, a));
  };

  public func view(s : State, _seat : TP.Seat, _over : Bool) : View = s;

  /// The functions the framework calls. Never stored by it: the host hands
  /// `spec` in on every call.
  public let spec : TP.Spec<State, Action, View, Options> = #turnBased {
    checkOptions;
    init;
    toMove;
    move;
    view;
  };
};
